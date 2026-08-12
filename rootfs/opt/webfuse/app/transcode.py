"""On-the-fly HLS transcoding via ffmpeg.

Non-browser-friendly files (MKV/HEVC/AC3/etc.) are transcoded to H.264 + AAC
and served as a growing HLS playlist, so they play — and can be seeked within
the already-transcoded range — in any browser (natively in Safari, via hls.js
elsewhere).

One ffmpeg process per media item. Local files are read directly (ffmpeg can
seek the input); remote (SMB) files are streamed to ffmpeg via stdin.
"""
from __future__ import annotations

import logging
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from .config import (
    DATA_DIR,
    FFMPEG_BIN,
    HLS_SEGMENT_SECONDS,
    TRANSCODE_CRF,
    TRANSCODE_PRESET,
)
from .models import MediaItem, Source
from .sources import build_source

log = logging.getLogger("webfuse.transcode")

TRANSCODE_ROOT = DATA_DIR / "transcode"
TRANSCODE_ROOT.mkdir(parents=True, exist_ok=True)

PLAYLIST_NAME = "index.m3u8"


def ffmpeg_available() -> bool:
    return shutil.which(FFMPEG_BIN) is not None


class TranscodeSession:
    def __init__(self, item: MediaItem, source: Source, audio_index: int = 0, offset: int = 0):
        self.item_id = item.id
        self.audio_index = audio_index
        self.offset = offset  # seconds; transcode starts here (for resume/seek)
        self.dir = TRANSCODE_ROOT / f"{item.id}_a{audio_index}_o{offset}"
        self.proc: Optional[subprocess.Popen] = None
        self._feeder: Optional[threading.Thread] = None
        self._fs_source = source
        self._item = item
        self.last_access = time.time()

    @property
    def playlist(self) -> Path:
        return self.dir / PLAYLIST_NAME

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def start(self):
        # Fresh output directory each start.
        if self.dir.exists():
            shutil.rmtree(self.dir, ignore_errors=True)
        self.dir.mkdir(parents=True, exist_ok=True)

        fs = build_source(self._fs_source)
        local = fs.local_path(self._item.rel_path)

        cmd = [FFMPEG_BIN, "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        # Start the transcode at the requested offset (resume/seek). Output
        # timestamps reset to 0 (hls.js normalizes them anyway); the client adds
        # `offset` back to recover the real position.
        if self.offset > 0:
            cmd += ["-ss", str(self.offset)]
        if local:
            cmd += ["-i", local]
        else:
            cmd += ["-i", "pipe:0"]
        cmd += [
            # First video + the selected audio track; ignore subtitles and MKV
            # font/cover attachments that break the HLS muxer. (Subtitles are
            # served separately as WebVTT so any language works in either mode.)
            "-map", "0:v:0",
            "-map", f"0:a:{self.audio_index}?",
            "-sn",
            "-c:v", "libx264",
            "-preset", TRANSCODE_PRESET,
            "-crf", str(TRANSCODE_CRF),
            "-profile:v", "high",
            "-level", "4.1",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-ac", "2",
            "-b:a", "160k",
            "-f", "hls",
            "-hls_time", str(HLS_SEGMENT_SECONDS),
            "-hls_list_size", "0",  # keep every segment in the playlist (seekable)
            "-hls_playlist_type", "event",
            "-hls_flags", "independent_segments",
            "-hls_segment_filename", str(self.dir / "seg%05d.ts"),
            str(self.playlist),
        ]

        log.info("transcode start item=%s local=%s", self.item_id, bool(local))
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if not local else subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

        if not local:
            self._feeder = threading.Thread(
                target=self._feed_stdin, args=(fs,), daemon=True
            )
            self._feeder.start()

    def _feed_stdin(self, fs):
        """Stream a remote file into ffmpeg's stdin."""
        try:
            with fs.open(self._item.rel_path) as f:
                while True:
                    chunk = f.read(1024 * 512)
                    if not chunk:
                        break
                    self.proc.stdin.write(chunk)
        except (BrokenPipeError, ValueError, OSError):
            pass  # ffmpeg exited / stdin closed — expected on stop or seek-restart
        finally:
            try:
                self.proc.stdin.close()
            except Exception:
                pass

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def cleanup(self):
        self.stop()
        shutil.rmtree(self.dir, ignore_errors=True)


_SESSIONS: dict[tuple, TranscodeSession] = {}
_LOCK = threading.Lock()

# Cap concurrent transcodes and stop ones no client has fetched from recently —
# a transcode covers the whole file, so without this they pile up and saturate
# the CPU long after the viewer has stopped watching.
MAX_SESSIONS = 3
IDLE_SECONDS = 90


def ensure_session(
    item: MediaItem, source: Source, audio_index: int = 0, offset: int = 0,
    timeout: float = 25.0,
) -> TranscodeSession:
    """Return a running session for (item, audio track, offset), starting one if
    needed. Blocks until the playlist has a first segment, or raises on timeout."""
    key = (item.id, audio_index, offset)
    with _LOCK:
        sess = _SESSIONS.get(key)
        if sess is None or (not sess.is_alive() and not sess.playlist.exists()):
            _enforce_cap_locked()
            sess = TranscodeSession(item, source, audio_index, offset)
            _SESSIONS[key] = sess
            sess.start()
        sess.last_access = time.time()

    deadline = time.time() + timeout
    while time.time() < deadline:
        if sess.playlist.exists() and any(sess.dir.glob("seg*.ts")):
            return sess
        if sess.proc and sess.proc.poll() not in (None, 0):
            err = _drain_stderr(sess)
            raise RuntimeError(f"ffmpeg failed: {err or 'unknown error'}")
        time.sleep(0.25)
    raise TimeoutError("transcode did not produce output in time")


def _enforce_cap_locked():
    """Stop the least-recently-used session(s) if at capacity. Caller holds _LOCK."""
    while len(_SESSIONS) >= MAX_SESSIONS:
        lru_key = min(_SESSIONS, key=lambda k: _SESSIONS[k].last_access)
        log.info("transcode cap reached; stopping LRU %s", lru_key)
        _SESSIONS.pop(lru_key).cleanup()


def get_session(item_id: int, audio_index: int = 0, offset: int = 0) -> Optional[TranscodeSession]:
    sess = _SESSIONS.get((item_id, audio_index, offset))
    if sess:
        sess.last_access = time.time()
    return sess


def reap_idle():
    """Stop sessions no client has touched within IDLE_SECONDS."""
    now = time.time()
    with _LOCK:
        for key in [k for k, s in _SESSIONS.items() if now - s.last_access > IDLE_SECONDS]:
            log.info("reaping idle transcode %s", key)
            _SESSIONS.pop(key).cleanup()


def _reaper_loop():
    while True:
        time.sleep(30)
        try:
            reap_idle()
        except Exception:
            log.exception("reaper error")


_reaper = threading.Thread(target=_reaper_loop, daemon=True)
_reaper.start()


def _drain_stderr(sess: TranscodeSession) -> str:
    try:
        if sess.proc and sess.proc.stderr:
            return sess.proc.stderr.read().decode("utf-8", "replace")[-500:]
    except Exception:
        pass
    return ""


def stop_all():
    with _LOCK:
        for sess in _SESSIONS.values():
            sess.cleanup()
        _SESSIONS.clear()
