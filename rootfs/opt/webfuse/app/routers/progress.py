"""Watch progress + resume: save position, mark watched, continue-watching."""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import MediaItem
from ..schemas import MediaOut

router = APIRouter(prefix="/api/progress", tags=["progress"])

# Fractions that count as "finished" (mark watched) or "not really started".
WATCHED_FRACTION = 0.92
START_THRESHOLD = 15.0  # seconds — below this we don't consider it "in progress"


class ProgressIn(BaseModel):
    position: float
    duration: float = 0.0


class WatchedIn(BaseModel):
    watched: bool


@router.post("/{item_id}")
def save_progress(item_id: int, payload: ProgressIn, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    item.position_seconds = max(0.0, payload.position)
    if payload.duration > 0:
        item.duration_seconds = payload.duration
    item.last_watched_at = datetime.utcnow()
    # Auto-mark watched near the end; clear the resume point so it restarts.
    if item.duration_seconds > 0 and payload.position >= item.duration_seconds * WATCHED_FRACTION:
        item.watched = True
        item.position_seconds = 0.0
    else:
        item.watched = False
    db.commit()
    return {"ok": True, "watched": item.watched}


@router.post("/{item_id}/watched")
def set_watched(item_id: int, payload: WatchedIn, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    item.watched = payload.watched
    item.position_seconds = 0.0
    item.last_watched_at = datetime.utcnow() if payload.watched else item.last_watched_at
    db.commit()
    return {"ok": True}


@router.get("/continue", response_model=list[MediaOut])
def continue_watching(db: Session = Depends(get_db), limit: int = 20):
    """In-progress, not-finished items, most recently watched first."""
    rows = db.scalars(
        select(MediaItem)
        .where(
            MediaItem.watched.is_(False),
            MediaItem.position_seconds > START_THRESHOLD,
            MediaItem.last_watched_at.isnot(None),
        )
        .order_by(MediaItem.last_watched_at.desc())
        .limit(limit)
    )
    return list(rows)
