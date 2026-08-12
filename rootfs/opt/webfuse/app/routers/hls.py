"""HLS transcoding endpoints (playlist + segments), per audio track + offset."""
from __future__ import annotations

import re

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import MediaItem, Source
from ..transcode import ensure_session, ffmpeg_available, get_session

router = APIRouter(prefix="/api/hls", tags=["hls"])

_SEG_RE = re.compile(r"^seg\d{5}\.ts$")
_AUDIO_RE = re.compile(r"^a(\d+)$")
_OFFSET_RE = re.compile(r"^o(\d+)$")


def _parse(audio: str, offset: str) -> tuple[int, int]:
    a = _AUDIO_RE.match(audio)
    o = _OFFSET_RE.match(offset)
    if not a or not o:
        raise HTTPException(404, "not found")
    return int(a.group(1)), int(o.group(1))


@router.get("/{item_id}/{audio}/{offset}/index.m3u8")
def playlist(item_id: int, audio: str, offset: str, db: Session = Depends(get_db)):
    if not ffmpeg_available():
        raise HTTPException(503, "ffmpeg not installed on the server")
    aidx, off = _parse(audio, offset)
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    source = db.get(Source, item.source_id)
    if not source:
        raise HTTPException(404, "source not found")
    try:
        sess = ensure_session(item, source, audio_index=aidx, offset=off)
    except (RuntimeError, TimeoutError) as e:
        raise HTTPException(500, str(e))
    return FileResponse(
        sess.playlist,
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-store"},
    )


@router.get("/{item_id}/{audio}/{offset}/{segment}")
def segment(item_id: int, audio: str, offset: str, segment: str):
    if not _SEG_RE.match(segment):
        raise HTTPException(404, "not found")
    aidx, off = _parse(audio, offset)
    sess = get_session(item_id, aidx, off)  # also refreshes last_access
    if not sess:
        raise HTTPException(404, "no active transcode session")
    path = sess.dir / segment
    if not path.exists():
        raise HTTPException(404, "segment not ready")
    return FileResponse(
        path, media_type="video/mp2t", headers={"Cache-Control": "no-store"}
    )
