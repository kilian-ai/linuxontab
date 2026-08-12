"""Scan a source: walk files, parse names with guessit, enrich via TMDB."""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

from guessit import guessit
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import VIDEO_EXTENSIONS
from .metadata import TMDBClient, cast_from_credits, genre_names
from .models import MediaItem, Source
from .sources import build_source

log = logging.getLogger("webfuse.scanner")

# In-memory scan progress, keyed by source id, surfaced via the API.
SCAN_STATUS: dict[int, dict] = {}


def _parse(filename: str) -> dict:
    try:
        return dict(guessit(filename))
    except Exception:  # guessit can be fussy on odd names
        return {}


def _title_from(guess: dict, fallback: str) -> str:
    title = guess.get("title")
    if isinstance(title, list):
        title = " ".join(str(t) for t in title)
    return str(title) if title else fallback


def _year_from(guess: dict) -> Optional[int]:
    y = guess.get("year")
    return int(y) if isinstance(y, int) else None


def _enrich_movie(item: MediaItem, tmdb: TMDBClient):
    match = tmdb.search_movie(item.parsed_title, item.year)
    if not match:
        return
    details = tmdb.movie_details(match["id"]) or match
    item.tmdb_id = match["id"]
    item.title = details.get("title") or item.parsed_title
    item.overview = details.get("overview")
    item.poster_path = details.get("poster_path")
    item.backdrop_path = details.get("backdrop_path")
    item.rating = details.get("vote_average")
    item.release_date = details.get("release_date")
    item.runtime = details.get("runtime")
    item.genres = genre_names(details)
    item.cast = cast_from_credits(details.get("credits"))
    item.matched = True


def _enrich_episode(item: MediaItem, tmdb: TMDBClient, show_cache: dict):
    key = item.parsed_title.lower()
    show = show_cache.get(key)
    if show is None:
        match = tmdb.search_tv(item.parsed_title)
        show = tmdb.tv_details(match["id"]) if match else None
        show_cache[key] = show or {}
        show = show_cache[key]
    if not show or "id" not in show:
        return

    item.show_tmdb_id = show["id"]
    item.title = show.get("name") or item.parsed_title
    item.poster_path = show.get("poster_path")
    item.backdrop_path = show.get("backdrop_path")
    item.rating = show.get("vote_average")
    item.genres = genre_names(show)
    item.cast = cast_from_credits(show.get("credits"))

    # Episode-specific details (title, still, overview) when we have S/E numbers.
    if item.season is not None and item.episode is not None:
        ep = tmdb.tv_episode(show["id"], item.season, item.episode)
        if ep:
            item.tmdb_id = ep.get("id")
            item.overview = ep.get("overview")
            item.release_date = ep.get("air_date")
            if ep.get("still_path"):
                item.backdrop_path = ep["still_path"]
    item.matched = True


def build_item(source_id: int, rel_path: str, size: int) -> MediaItem:
    """Create an unsaved MediaItem from a file path (filename-parsed only)."""
    name = rel_path.split("/")[-1]
    guess = _parse(name)
    is_episode = guess.get("type") == "episode" or (
        "episode" in guess and "season" in guess
    )
    return MediaItem(
        source_id=source_id,
        rel_path=rel_path,
        file_size=size,
        container=rel_path.rsplit(".", 1)[-1].lower(),
        media_type="episode" if is_episode else "movie",
        parsed_title=_title_from(guess, name),
        year=_year_from(guess),
        season=guess.get("season") if isinstance(guess.get("season"), int) else None,
        episode=guess.get("episode") if isinstance(guess.get("episode"), int) else None,
    )


def enrich_item(item: MediaItem, tmdb: TMDBClient, show_cache: dict):
    if not tmdb.enabled or item.matched:
        return
    try:
        if item.media_type == "movie":
            _enrich_movie(item, tmdb)
        else:
            _enrich_episode(item, tmdb, show_cache)
    except Exception:
        log.exception("enrich failed for %s", item.rel_path)


def scan_source(db: Session, source: Source) -> dict:
    """Walk a source, upsert MediaItem rows, and enrich them via TMDB."""
    tmdb = TMDBClient()
    show_cache: dict = {}
    fs = build_source(source)

    SCAN_STATUS[source.id] = {"state": "scanning", "found": 0, "added": 0, "matched": 0}
    status = SCAN_STATUS[source.id]

    existing = {
        row.rel_path: row
        for row in db.scalars(
            select(MediaItem).where(MediaItem.source_id == source.id)
        )
    }
    seen: set[str] = set()

    for rf in fs.iter_files():
        seen.add(rf.rel_path)
        status["found"] += 1
        item = existing.get(rf.rel_path)
        if item is None:
            item = build_item(source.id, rf.rel_path, rf.size)
            db.add(item)
            status["added"] += 1

        if tmdb.enabled and not item.matched:
            enrich_item(item, tmdb, show_cache)
            if item.matched:
                status["matched"] += 1

        db.commit()

    # Remove rows for files that vanished.
    for rel_path, row in existing.items():
        if rel_path not in seen:
            db.delete(row)

    source.last_scanned_at = datetime.utcnow()
    db.commit()
    tmdb.close()

    status["state"] = "done"
    return status
