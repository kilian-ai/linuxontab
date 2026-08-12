"""Surface Transmission torrents as library items so in-progress downloads
appear (with progress) before the file is fully downloaded/scanned."""
from __future__ import annotations

import logging
import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from .metadata import TMDBClient
from .models import MediaItem, Source
from .scanner import build_item, enrich_item
from .torrents import TransmissionClient, TransmissionError, video_files

log = logging.getLogger("webfuse.torrent_library")

# Throttle: sync at most this often (Transmission RPC on every library GET
# would be wasteful). Cheap no-op when nothing is downloading.
_MIN_INTERVAL = 3.0
_last_sync = 0.0


def _match_source(sources: list[Source], abs_path: str):
    """Longest-prefix match of a download path to a local source."""
    best = None
    for s in sources:
        if s.kind != "local":
            continue
        root = s.path.rstrip("/")
        if abs_path == root or abs_path.startswith(root + "/"):
            if best is None or len(root) > len(best.path.rstrip("/")):
                best = s
    return best


def sync(db: Session, force: bool = False) -> int:
    """Upsert a MediaItem for each torrent's main video file. Returns the number
    of items touched. Safe to call often (throttled, and TMDB only on first
    sight of an item)."""
    global _last_sync
    now = time.monotonic()
    if not force and now - _last_sync < _MIN_INTERVAL:
        return 0
    _last_sync = now

    client = TransmissionClient()
    try:
        torrents = client.detail()
    except TransmissionError:
        return 0  # Transmission down — library still works from disk
    finally:
        client.close()

    sources = list(db.scalars(select(Source)))
    tmdb = TMDBClient()
    show_cache: dict = {}
    touched = 0

    for t in torrents:
        download_dir = (t.get("downloadDir") or "").rstrip("/")
        for _idx, f in video_files(t):  # one item per file (season packs)
            # Per-file completeness (a pack's early episodes finish first).
            downloading = f.get("bytesCompleted", 0) < f["length"]
            abs_path = f"{download_dir}/{f['name']}"
            source = _match_source(sources, abs_path)
            if source is None:
                continue
            root = source.path.rstrip("/")
            rel_path = abs_path[len(root):].lstrip("/")

            item = db.scalar(
                select(MediaItem).where(
                    MediaItem.source_id == source.id, MediaItem.rel_path == rel_path
                )
            )
            if item is None:
                item = build_item(source.id, rel_path, f["length"])
                item.torrent_hash = t.get("hashString")
                item.downloading = downloading
                db.add(item)
                enrich_item(item, tmdb, show_cache)
            else:
                item.torrent_hash = t.get("hashString")
                item.downloading = downloading
                if not item.file_size:
                    item.file_size = f["length"]
            touched += 1

    db.commit()
    tmdb.close()
    return touched
