"""Subtitle endpoints: list tracks and serve WebVTT."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse, Response
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import MediaItem, Source
from ..subtitles import get_vtt, list_tracks, shift_vtt

router = APIRouter(prefix="/api/subtitles", tags=["subtitles"])


def _item_source(item_id: int, db: Session):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    source = db.get(Source, item.source_id)
    if not source:
        raise HTTPException(404, "source not found")
    return item, source


@router.get("/{item_id}")
def subtitle_tracks(item_id: int, db: Session = Depends(get_db)):
    item, source = _item_source(item_id, db)
    try:
        return list_tracks(item, source)
    except Exception:
        return []


@router.get("/{item_id}/track.vtt")
def subtitle_vtt(
    item_id: int,
    id: str = Query(...),
    offset: float = Query(0.0),
    db: Session = Depends(get_db),
):
    item, source = _item_source(item_id, db)
    path = get_vtt(item, source, id)
    if not path:
        raise HTTPException(404, "subtitle unavailable")
    # For offset (transcoded resume/seek) playback, shift cue times to match the
    # window-relative video timeline.
    if offset and offset > 0:
        shifted = shift_vtt(path.read_bytes(), offset)
        return Response(content=shifted, media_type="text/vtt",
                        headers={"Cache-Control": "no-store"})
    return FileResponse(
        path, media_type="text/vtt",
        headers={"Cache-Control": "public, max-age=3600"},
    )
