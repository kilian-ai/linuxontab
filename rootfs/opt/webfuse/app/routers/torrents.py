"""BitTorrent endpoints: search (Torznab), add magnet, progress, remove."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from pydantic import BaseModel

from ..db import get_db
from ..models import MediaItem
from ..torrents import (
    TransmissionClient,
    TransmissionError,
    file_stream_info,
    find_file_index,
    search_configured,
    search_provider,
    search_torrents,
)

router = APIRouter(prefix="/api/torrents", tags=["torrents"])


class MagnetIn(BaseModel):
    magnet: str


@router.get("/status")
def torrent_status():
    """Is the BitTorrent integration usable?"""
    out = {
        "search_enabled": search_configured(),
        "search_provider": search_provider(),
        "transmission": None,
        "error": None,
    }
    client = TransmissionClient()
    try:
        out["transmission"] = client.ping()
    except TransmissionError as e:
        out["error"] = str(e)
    finally:
        client.close()
    return out


@router.get("/search")
def search(q: str = Query(min_length=2), limit: int = 30):
    if not search_configured():
        raise HTTPException(
            503,
            "No torrent indexer configured. Set PROWLARR_URL/PROWLARR_APIKEY "
            "(or TORZNAB_URL/TORZNAB_APIKEY) in backend/.env.",
        )
    try:
        return search_torrents(q, limit)
    except Exception as e:
        raise HTTPException(502, f"indexer search failed: {e}")


@router.get("")
def list_torrents(db: Session = Depends(get_db)):
    from ..torrent_library import sync as sync_torrents

    client = TransmissionClient()
    try:
        result = client.list_torrents()
    except TransmissionError as e:
        raise HTTPException(502, str(e))
    finally:
        client.close()
    try:
        sync_torrents(db)  # keep library rows in step with torrent progress
    except Exception:
        pass
    return result


@router.post("")
def add_torrent(payload: MagnetIn, db: Session = Depends(get_db)):
    from ..torrent_library import sync as sync_torrents

    link = payload.magnet.strip()
    if not (link.startswith("magnet:") or link.startswith(("http://", "https://"))):
        raise HTTPException(400, "expected a magnet: link or a .torrent URL")
    client = TransmissionClient()
    try:
        added = client.add_magnet(link)
    except TransmissionError as e:
        raise HTTPException(502, str(e))
    finally:
        client.close()
    try:
        sync_torrents(db, force=True)  # try to surface it right away
    except Exception:
        pass
    return added


@router.get("/piecemap/{item_id}")
def piecemap(item_id: int, db: Session = Depends(get_db)):
    """Download progress + piece-availability map for a torrent-backed item."""
    item = db.get(MediaItem, item_id)
    if not item or not item.torrent_hash:
        raise HTTPException(404, "item is not backed by a torrent")
    client = TransmissionClient()
    try:
        torrents = client.detail(ids=[item.torrent_hash])
    except TransmissionError as e:
        raise HTTPException(502, str(e))
    finally:
        client.close()
    if not torrents:
        raise HTTPException(404, "torrent no longer present")
    t = torrents[0]
    idx, f = find_file_index(t, item.rel_path)
    if idx is None:
        raise HTTPException(404, "no video file in torrent")
    info = file_stream_info(t, idx)
    info.update(
        {
            "status": {0: "stopped", 1: "check-wait", 2: "checking", 3: "download-wait",
                       4: "downloading", 5: "seed-wait", 6: "seeding"}.get(t.get("status"), "unknown"),
            "rate_down": t.get("rateDownload", 0),
            "peers": t.get("peersSendingToUs", 0),
            "eta": t.get("eta", -1),
            "error": t.get("errorString") or None,
        }
    )
    return info


@router.delete("/{torrent_id}")
def remove_torrent(torrent_id: int, delete_data: bool = False):
    client = TransmissionClient()
    try:
        client.remove(torrent_id, delete_data)
        return {"ok": True}
    except TransmissionError as e:
        raise HTTPException(502, str(e))
    finally:
        client.close()
