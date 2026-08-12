"""Subtitle serving: external sidecars + embedded tracks, converted to WebVTT
and cached on disk."""
from __future__ import annotations

import logging
import re
import subprocess
import threading
from pathlib import Path
from typing import Optional

from .config import DATA_DIR, FFMPEG_BIN
from .models import MediaItem
from .sources import build_source
from .tracks import external_subtitles, probe_streams

log = logging.getLogger("webfuse.subtitles")

SUB_CACHE = DATA_DIR / "subtitles"
SUB_CACHE.mkdir(parents=True, exist_ok=True)

_locks: dict[int, threading.Lock] = {}
_locks_guard = threading.Lock()


def _lock_for(item_id: int) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(item_id, threading.Lock())


def _cache_dir(item_id: int) -> Path:
    d = SUB_CACHE / str(item_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


def _safe(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def list_tracks(item: MediaItem, source) -> list[dict]:
    """All subtitle tracks for an item as [{id, lang, label, source}]."""
    fs = build_source(source)
    tracks = []

    # External sidecars (work for local + SMB).
    for i, ext in enumerate(external_subtitles(fs, item.rel_path)):
        tracks.append({
            "id": f"ext:{ext['filename']}",
            "lang": ext["lang"], "label": ext["label"], "source": "external",
        })

    # Embedded text subtitles (need a local path to probe).
    local = fs.local_path(item.rel_path)
    if local and not item.downloading:
        for s in probe_streams(local)["subtitle"]:
            if not s["text_based"]:
                continue
            tracks.append({
                "id": f"emb:{s['index']}",
                "lang": s["lang"], "label": s["label"], "source": "embedded",
            })
    return tracks


def get_vtt(item: MediaItem, source, track_id: str) -> Optional[Path]:
    """Return a path to the cached WebVTT for a track, extracting if needed."""
    fs = build_source(source)
    cache = _cache_dir(item.id)

    if track_id.startswith("ext:"):
        filename = track_id[4:]
        out = cache / f"ext_{_safe(filename)}.vtt"
        if out.exists():
            return out
        rel = item.rel_path.replace("\\", "/")
        sib_rel = (rel.rsplit("/", 1)[0] + "/" + filename) if "/" in rel else filename
        with _lock_for(item.id):
            if out.exists():
                return out
            try:
                with fs.open(sib_rel) as f:
                    data = f.read()
            except OSError:
                return None
            if filename.lower().endswith(".vtt"):
                out.write_bytes(data)
            else:
                vtt = _convert_bytes_to_vtt(data)
                if vtt is None:
                    return None
                out.write_bytes(vtt)
        return out

    if track_id.startswith("emb:"):
        idx = int(track_id[4:])
        out = cache / f"emb_{idx}.vtt"
        if out.exists():
            return out
        local = fs.local_path(item.rel_path)
        if not local:
            return None
        with _lock_for(item.id):
            if not out.exists():
                _extract_all_embedded(local, cache)
        return out if out.exists() else None

    return None


_TS = re.compile(
    r"(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})\s*-->\s*(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})(.*)"
)


def _fmt_ts(sec: float) -> str:
    if sec < 0:
        sec = 0
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def shift_vtt(data: bytes, offset: float) -> bytes:
    """Shift all cue timings by -offset (for offset/transcoded playback), dropping
    cues that end before the window start."""
    out = []
    for line in data.decode("utf-8", "replace").splitlines():
        m = _TS.match(line.strip())
        if not m:
            out.append(line)
            continue
        start = (int(m[1] or 0) * 3600 + int(m[2]) * 60 + int(m[3]) + int(m[4]) / 1000) - offset
        end = (int(m[5] or 0) * 3600 + int(m[6]) * 60 + int(m[7]) + int(m[8]) / 1000) - offset
        if end <= 0:
            out.append("__DROP__")  # cue fully before the window
            continue
        out.append(f"{_fmt_ts(start)} --> {_fmt_ts(end)}{m[9]}")
    # Drop cue blocks whose timing line was marked; keep it simple: strip the
    # dropped timing lines and their following text until a blank line.
    result, skip = [], False
    for line in out:
        if line == "__DROP__":
            skip = True
            continue
        if skip:
            if line.strip() == "":
                skip = False
            continue
        result.append(line)
    return ("\n".join(result) + "\n").encode("utf-8")


def _convert_bytes_to_vtt(data: bytes) -> Optional[bytes]:
    """Convert SRT/ASS bytes to WebVTT via ffmpeg stdin→stdout."""
    try:
        p = subprocess.run(
            [FFMPEG_BIN, "-v", "error", "-i", "pipe:0", "-f", "webvtt", "pipe:1"],
            input=data, capture_output=True, timeout=30,
        )
        return p.stdout or None
    except (subprocess.TimeoutExpired, OSError):
        return None


def _extract_all_embedded(local_path: str, cache: Path):
    """One ffmpeg pass extracting every text subtitle stream to emb_<i>.vtt
    (reads the container once, then all languages are cached)."""
    streams = probe_streams(local_path)["subtitle"]
    text = [s for s in streams if s["text_based"]]
    if not text:
        return
    cmd = [FFMPEG_BIN, "-y", "-v", "error", "-i", local_path]
    for s in text:
        cmd += ["-map", f"0:s:{s['index']}", "-c:s", "webvtt",
                str(cache / f"emb_{s['index']}.vtt")]
    log.info("extracting %d embedded subs from %s", len(text), local_path)
    try:
        subprocess.run(cmd, capture_output=True, timeout=300)
    except (subprocess.TimeoutExpired, OSError):
        log.warning("embedded subtitle extraction timed out")
