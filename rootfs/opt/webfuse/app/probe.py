"""ffprobe-based codec detection to decide direct-play vs. transcode."""
from __future__ import annotations

import json
import logging
import shutil
import subprocess
from typing import Optional

from .config import (
    BROWSER_AUDIO_CODECS,
    BROWSER_FRIENDLY_CONTAINERS,
    BROWSER_VIDEO_CODECS,
    FFPROBE_BIN,
)

log = logging.getLogger("webfuse.probe")

# For SMB (piped) probing, feed ffprobe at most this many bytes. Enough to read
# the header of most formats without streaming the whole file.
_PIPE_LIMIT = 16 * 1024 * 1024


def ffprobe_available() -> bool:
    return shutil.which(FFPROBE_BIN) is not None


def _parse(stdout: bytes) -> Optional[dict]:
    try:
        data = json.loads(stdout)
    except (ValueError, TypeError):
        return None
    video = audio = None
    for s in data.get("streams", []):
        if s.get("codec_type") == "video" and video is None:
            # Ignore cover-art / attached-pic "video" streams.
            if s.get("disposition", {}).get("attached_pic"):
                continue
            video = s.get("codec_name")
        elif s.get("codec_type") == "audio" and audio is None:
            audio = s.get("codec_name")
    return {"video": video, "audio": audio}


def probe_codecs(fs, rel_path: str) -> Optional[dict]:
    """Return {'video': codec, 'audio': codec} or None if probing failed."""
    if not ffprobe_available():
        return None
    args = [
        FFPROBE_BIN, "-v", "error",
        "-show_entries", "stream=codec_type,codec_name,disposition",
        "-of", "json",
    ]
    local = fs.local_path(rel_path)
    try:
        if local:
            out = subprocess.run(
                args + [local], capture_output=True, timeout=30
            ).stdout
            return _parse(out)
        return _probe_via_pipe(fs, rel_path, args)
    except (subprocess.TimeoutExpired, OSError):
        return None


def _probe_via_pipe(fs, rel_path: str, args) -> Optional[dict]:
    proc = subprocess.Popen(
        args + ["-i", "pipe:0"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        with fs.open(rel_path) as f:
            fed = 0
            while fed < _PIPE_LIMIT:
                chunk = f.read(512 * 1024)
                if not chunk:
                    break
                try:
                    proc.stdin.write(chunk)
                except (BrokenPipeError, OSError):
                    break
                fed += len(chunk)
    except OSError:
        pass
    finally:
        try:
            proc.stdin.close()  # signal EOF so ffprobe finishes
        except Exception:
            pass
    # Read stdout directly — stdin is already closed, so don't use communicate()
    # (it would try to flush the closed stdin and raise).
    try:
        out = proc.stdout.read()
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        return None
    finally:
        try:
            proc.stdout.close()
        except Exception:
            pass
    return _parse(out)


def decide_playback(container: str, video_codec: Optional[str], audio_codec: Optional[str]) -> dict:
    """Return {'mode': 'direct'|'hls', 'reason': str} for a media item.

    Falls back to a container-only heuristic when codecs are unknown.
    """
    container = (container or "").lower()
    if container not in BROWSER_FRIENDLY_CONTAINERS:
        return {"mode": "hls", "reason": f"{container.upper()} container not supported by browsers"}

    v = (video_codec or "").lower()
    a = (audio_codec or "").lower()
    if v and v not in BROWSER_VIDEO_CODECS:
        return {"mode": "hls", "reason": f"{v} video not supported by browsers"}
    if a and a not in BROWSER_AUDIO_CODECS:
        return {"mode": "hls", "reason": f"{a} audio not supported by browsers"}
    return {"mode": "direct", "reason": "browser-compatible"}
