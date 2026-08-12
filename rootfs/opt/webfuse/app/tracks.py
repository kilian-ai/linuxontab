"""Audio + subtitle track detection (embedded via ffprobe, external sidecars)."""
from __future__ import annotations

import json
import os
import subprocess
from typing import Optional

from .config import FFPROBE_BIN

# Subtitle codecs we can turn into WebVTT. Image-based subs (PGS/VOBSUB/DVD)
# can't be converted without OCR/burn-in and are reported as unsupported.
TEXT_SUB_CODECS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}
SIDECAR_EXTS = {".srt", ".vtt", ".ass", ".ssa"}

# ISO 639-2 (ffprobe) → BCP-47 (for <track srclang>) + display name.
_LANG = {
    "eng": ("en", "English"), "spa": ("es", "Spanish"), "fre": ("fr", "French"),
    "fra": ("fr", "French"), "ger": ("de", "German"), "deu": ("de", "German"),
    "ita": ("it", "Italian"), "dut": ("nl", "Dutch"), "nld": ("nl", "Dutch"),
    "por": ("pt", "Portuguese"), "rus": ("ru", "Russian"), "jpn": ("ja", "Japanese"),
    "chi": ("zh", "Chinese"), "zho": ("zh", "Chinese"), "kor": ("ko", "Korean"),
    "ara": ("ar", "Arabic"), "hin": ("hi", "Hindi"), "swe": ("sv", "Swedish"),
    "nor": ("no", "Norwegian"), "dan": ("da", "Danish"), "fin": ("fi", "Finnish"),
    "pol": ("pl", "Polish"), "tur": ("tr", "Turkish"), "gre": ("el", "Greek"),
    "ell": ("el", "Greek"), "heb": ("he", "Hebrew"), "cze": ("cs", "Czech"),
    "ces": ("cs", "Czech"), "hun": ("hu", "Hungarian"), "tha": ("th", "Thai"),
    "vie": ("vi", "Vietnamese"), "ind": ("id", "Indonesian"), "ukr": ("uk", "Ukrainian"),
    "rum": ("ro", "Romanian"), "ron": ("ro", "Romanian"), "bul": ("bg", "Bulgarian"),
    "hrv": ("hr", "Croatian"), "srp": ("sr", "Serbian"), "slo": ("sk", "Slovak"),
    "slk": ("sk", "Slovak"), "slv": ("sl", "Slovenian"), "est": ("et", "Estonian"),
    "lav": ("lv", "Latvian"), "lit": ("lt", "Lithuanian"), "may": ("ms", "Malay"),
    "msa": ("ms", "Malay"), "tam": ("ta", "Tamil"), "tel": ("te", "Telugu"),
}
# BCP-47 (2-letter) → display name, so sidecar codes like "en"/"nl" get names.
_BCP_NAME = {cc: n for cc, n in _LANG.values()}
# Also accept full English names as sidecar language tags (e.g. "Movie.english.srt").
_NAME_BCP = {n.lower(): cc for cc, n in _LANG.values()}


def lang_info(code: Optional[str]):
    """(bcp47, display_name) for an ffprobe/sidecar language tag."""
    if not code:
        return ("und", "Unknown")
    code = code.lower()
    if code in _LANG:  # 3-letter ISO 639-2
        return _LANG[code]
    if code in _BCP_NAME:  # 2-letter BCP-47
        return (code, _BCP_NAME[code])
    if code in _NAME_BCP:  # full English name
        return (_NAME_BCP[code], code.capitalize())
    return (code, code.upper())


def probe_streams(local_path: str) -> dict:
    """Return {'audio': [...], 'subtitle': [...], 'duration': float}."""
    try:
        out = subprocess.run(
            [FFPROBE_BIN, "-v", "error", "-print_format", "json",
             "-show_entries",
             "format=duration:stream=index,codec_type,codec_name,channels:stream_tags=language,title:stream_disposition=default",
             local_path],
            capture_output=True, timeout=30,
        ).stdout
        data = json.loads(out)
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return {"audio": [], "subtitle": [], "duration": 0.0}

    try:
        duration = float(data.get("format", {}).get("duration", 0) or 0)
    except (TypeError, ValueError):
        duration = 0.0
    audio, subtitle = [], []
    ai = si = 0
    for s in data.get("streams", []):
        ctype = s.get("codec_type")
        tags = s.get("tags", {}) or {}
        disp = s.get("disposition", {}) or {}
        lang = tags.get("language")
        bcp, name = lang_info(lang)
        title = tags.get("title")
        if ctype == "audio":
            label = title or name
            ch = s.get("channels")
            if ch == 6:
                label += " 5.1"
            elif ch == 2:
                label += " 2.0"
            audio.append({
                "index": ai, "lang": bcp, "label": label,
                "channels": ch, "default": bool(disp.get("default")),
            })
            ai += 1
        elif ctype == "subtitle":
            subtitle.append({
                "index": si, "lang": bcp, "label": title or name,
                "codec": s.get("codec_name"),
                "text_based": s.get("codec_name") in TEXT_SUB_CODECS,
                "default": bool(disp.get("default")),
            })
            si += 1
    return {"audio": audio, "subtitle": subtitle, "duration": duration}


def probe_chapters(local_path: str) -> list[dict]:
    """Chapter markers [{start, end, title}] (empty if none / on error)."""
    try:
        out = subprocess.run(
            [FFPROBE_BIN, "-v", "error", "-print_format", "json",
             "-show_chapters", local_path],
            capture_output=True, timeout=20,
        ).stdout
        data = json.loads(out)
    except (subprocess.TimeoutExpired, OSError, ValueError):
        return []
    chapters = []
    for c in data.get("chapters", []):
        try:
            chapters.append({
                "start": float(c.get("start_time", 0)),
                "end": float(c.get("end_time", 0)),
                "title": (c.get("tags", {}) or {}).get("title", ""),
            })
        except (TypeError, ValueError):
            continue
    return chapters


_INTRO_WORDS = ("intro", "opening", "recap", "main title", "op credits", "titles")


def detect_intro(local_path: Optional[str], is_episode: bool) -> Optional[dict]:
    """Return an intro marker {start, end, source} or None.

    Prefers chapter markers (accurate); falls back to a fixed offset for episodes
    so a user can skip a typical intro even when the file has no chapters.
    """
    from .config import DEFAULT_INTRO_END

    chapters = probe_chapters(local_path) if local_path else []
    # Named intro/recap chapters near the start: skip to the end of the last one
    # (handles Recap → Intro sequences by skipping past both).
    named_end = 0.0
    for c in chapters:
        title = (c["title"] or "").lower()
        if any(w in title for w in _INTRO_WORDS) and c["start"] < 180 and 5 < c["end"] < 300:
            named_end = max(named_end, c["end"])
    if named_end > 0:
        return {"start": 0.0, "end": named_end, "source": "chapter"}
    # Unnamed chapters: a first boundary landing in a plausible intro window.
    if len(chapters) >= 2:
        first_end = chapters[0]["end"]
        if 20 <= first_end <= 180 and chapters[0]["start"] < 30:
            return {"start": 0.0, "end": first_end, "source": "chapter"}
    if is_episode:
        return {"start": 0.0, "end": float(DEFAULT_INTRO_END), "source": "heuristic"}
    return None


def external_subtitles(fs, rel_path: str) -> list[dict]:
    """Sidecar subtitle files next to the video, matched by name stem."""
    base = rel_path.replace("\\", "/").rsplit("/", 1)[-1]
    stem = os.path.splitext(base)[0].lower()
    results = []
    for name in fs.siblings(rel_path):
        root, ext = os.path.splitext(name)
        if ext.lower() not in SIDECAR_EXTS:
            continue
        rl = root.lower()
        if rl != stem and not rl.startswith(stem):
            continue
        # Language from the suffix after the stem, e.g. "Movie.en.srt".
        suffix = root[len(stem):].strip(". _-") if rl.startswith(stem) else ""
        parts = [p for p in suffix.replace("_", ".").split(".") if p]
        lang_code = parts[0] if parts else None
        bcp, disp = lang_info(lang_code) if lang_code else ("und", "External")
        forced = any(p.lower() in ("forced", "sdh") for p in parts)
        label = disp + (" [Forced]" if "forced" in suffix.lower() else "") + (" [SDH]" if "sdh" in suffix.lower() else "")
        results.append({
            "lang": bcp, "label": label, "filename": name, "ext": ext.lower().lstrip("."),
        })
    return results
