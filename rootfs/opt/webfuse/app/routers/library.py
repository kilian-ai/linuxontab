"""Browse the discovered library: movies, shows, and item details."""
from __future__ import annotations

from collections import defaultdict
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import MediaItem
from ..schemas import MediaOut, ShowOut
from ..torrent_library import sync as sync_torrents

router = APIRouter(prefix="/api/library", tags=["library"])


@router.get("/movies", response_model=list[MediaOut])
def list_movies(
    db: Session = Depends(get_db),
    q: Optional[str] = Query(default=None),
):
    sync_torrents(db)  # surface in-progress torrent downloads (throttled)
    stmt = select(MediaItem).where(MediaItem.media_type == "movie")
    rows = list(db.scalars(stmt))
    if q:
        ql = q.lower()
        rows = [r for r in rows if ql in (r.title or r.parsed_title).lower()]
    rows.sort(key=lambda r: (r.title or r.parsed_title).lower())
    return rows


@router.get("/shows", response_model=list[ShowOut])
def list_shows(db: Session = Depends(get_db)):
    """Group episodes into shows."""
    sync_torrents(db)
    rows = list(
        db.scalars(select(MediaItem).where(MediaItem.media_type == "episode"))
    )
    groups: dict = defaultdict(list)
    for r in rows:
        key = r.show_tmdb_id or f"name:{r.parsed_title.lower()}"
        groups[key].append(r)

    shows = []
    for key, eps in groups.items():
        sample = next((e for e in eps if e.matched), eps[0])
        shows.append(
            ShowOut(
                show_tmdb_id=sample.show_tmdb_id,
                title=sample.title or sample.parsed_title,
                poster_path=sample.poster_path,
                backdrop_path=sample.backdrop_path,
                overview=sample.overview,
                rating=sample.rating,
                genres=sample.genres,
                cast=sample.cast,
                episode_count=len(eps),
            )
        )
    shows.sort(key=lambda s: s.title.lower())
    return shows


@router.get("/shows/{show_key}/episodes", response_model=list[MediaOut])
def show_episodes(show_key: str, db: Session = Depends(get_db)):
    """Episodes for a show, keyed by tmdb id (numeric) or 'name:<title>'."""
    rows = list(
        db.scalars(select(MediaItem).where(MediaItem.media_type == "episode"))
    )
    if show_key.startswith("name:"):
        name = show_key[5:].lower()
        eps = [r for r in rows if r.parsed_title.lower() == name]
    else:
        try:
            tmdb_id = int(show_key)
        except ValueError:
            raise HTTPException(400, "invalid show key")
        eps = [r for r in rows if r.show_tmdb_id == tmdb_id]
    eps.sort(key=lambda r: (r.season or 0, r.episode or 0))
    return eps


@router.get("/items/{item_id}", response_model=MediaOut)
def get_item(item_id: int, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    return item


def next_episode_item(db: Session, item: MediaItem) -> Optional[MediaItem]:
    """The next episode of the same show after `item`, or None."""
    if item.media_type != "episode":
        return None
    show_key = item.show_tmdb_id
    rows = [
        r for r in db.scalars(select(MediaItem).where(MediaItem.media_type == "episode"))
        if (r.show_tmdb_id == show_key if show_key is not None
            else r.parsed_title.lower() == item.parsed_title.lower())
    ]
    # One representative file per (season, episode): prefer a matched, larger file.
    best: dict = {}
    for r in rows:
        key = (r.season or 0, r.episode or 0)
        cur = best.get(key)
        if cur is None or (r.matched, r.file_size) > (cur.matched, cur.file_size):
            best[key] = r
    order = sorted(best)
    cur_key = (item.season or 0, item.episode or 0)
    try:
        idx = order.index(cur_key)
    except ValueError:
        return None
    return best[order[idx + 1]] if idx + 1 < len(order) else None


@router.get("/next/{item_id}", response_model=Optional[MediaOut])
def next_episode(item_id: int, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    return next_episode_item(db, item)
