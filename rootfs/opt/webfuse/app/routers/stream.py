"""Byte-range streaming for local and SMB files (enables in-browser seeking)."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import MediaItem, Source
from ..sources import build_source
from ..torrents import (
    TransmissionClient,
    TransmissionError,
    file_stream_info,
    find_file_index,
)

router = APIRouter(prefix="/api/stream", tags=["stream"])


def _streamable_limit(item: MediaItem, size: int) -> int:
    """For an in-progress torrent, the number of contiguously-available bytes
    from the start of the file. Full size for everything else."""
    if not (item.downloading and item.torrent_hash):
        return size
    client = TransmissionClient()
    try:
        torrents = client.detail(ids=[item.torrent_hash])
    except TransmissionError:
        return size  # best effort — assume available
    finally:
        client.close()
    if not torrents:
        return size
    idx, f = find_file_index(torrents[0], item.rel_path)
    if idx is None:
        return size
    info = file_stream_info(torrents[0], idx)
    return min(size, info["streamable_bytes"]) if not info["complete"] else size

CHUNK = 1024 * 1024  # 1 MiB

# Cap for open-ended range requests ("bytes=N-"). Browsers ask for the rest of
# the file but are happy with a shorter 206 window and simply request the next
# window when needed. Without a cap, one <video> request could hold a worker
# streaming gigabytes from SMB.
MAX_OPEN_RANGE = 32 * 1024 * 1024  # 32 MiB

CONTENT_TYPES = {
    "mp4": "video/mp4",
    "m4v": "video/mp4",
    "mov": "video/quicktime",
    "webm": "video/webm",
    "mkv": "video/x-matroska",
    "avi": "video/x-msvideo",
    "ts": "video/mp2t",
    "m2ts": "video/mp2t",
    "mpg": "video/mpeg",
    "mpeg": "video/mpeg",
    "wmv": "video/x-ms-wmv",
    "flv": "video/x-flv",
}


def _parse_range(header: str, size: int) -> tuple[int, int]:
    """Return (start, end) inclusive for a single-range 'bytes=' request."""
    try:
        units, rng = header.split("=", 1)
        if units.strip() != "bytes":
            raise ValueError
        start_s, end_s = rng.split("-", 1)
        if start_s == "":  # suffix range: last N bytes
            length = int(end_s)
            start = max(0, size - length)
            end = size - 1
        else:
            start = int(start_s)
            if end_s:
                end = int(end_s)
            else:
                # Open-ended request: serve a bounded window (see MAX_OPEN_RANGE).
                end = start + MAX_OPEN_RANGE - 1
        end = min(end, size - 1)
        if start > end or start < 0:
            raise ValueError
        return start, end
    except (ValueError, AttributeError):
        raise HTTPException(416, "invalid range")


@router.get("/{item_id}")
def stream(item_id: int, request: Request, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    source = db.get(Source, item.source_id)
    if not source:
        raise HTTPException(404, "source not found")

    fs = build_source(source)
    # Prefer the size recorded at scan time — avoids an SMB round-trip on every
    # single range request (a video fires many).
    size = item.file_size
    if not size:
        try:
            size = fs.size(item.rel_path)
        except OSError:
            raise HTTPException(404, "file unavailable")

    content_type = CONTENT_TYPES.get(item.container, "application/octet-stream")
    range_header = request.headers.get("range")

    # For an in-progress torrent, only bytes already downloaded (contiguously
    # from the start) may be served.
    avail = _streamable_limit(item, size)

    if range_header is None:
        # Full-content response, still advertise range support.
        def full():
            f = fs.open(item.rel_path)
            try:
                remaining = avail
                while remaining > 0 and (chunk := f.read(min(CHUNK, remaining))):
                    remaining -= len(chunk)
                    yield chunk
            finally:
                f.close()

        return StreamingResponse(
            full(),
            media_type=content_type,
            headers={"Accept-Ranges": "bytes", "Content-Length": str(size)},
        )

    start, end = _parse_range(range_header, size)
    # Seeking past what's downloaded yet: tell the client this range isn't ready.
    if start >= avail:
        return Response(
            status_code=416,
            headers={
                "Content-Range": f"bytes */{size}",
                "X-Streamable-Bytes": str(avail),
            },
        )
    end = min(end, avail - 1)
    length = end - start + 1

    def partial():
        f = fs.open(item.rel_path)
        try:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(CHUNK, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk
        finally:
            f.close()

    headers = {
        "Content-Range": f"bytes {start}-{end}/{size}",
        "Accept-Ranges": "bytes",
        "Content-Length": str(length),
    }
    return StreamingResponse(
        partial(), status_code=206, media_type=content_type, headers=headers
    )


@router.head("/{item_id}")
def stream_head(item_id: int, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    source = db.get(Source, item.source_id)
    size = item.file_size
    if not size:
        fs = build_source(source)
        try:
            size = fs.size(item.rel_path)
        except OSError:
            raise HTTPException(404, "file unavailable")
    content_type = CONTENT_TYPES.get(item.container, "application/octet-stream")
    return Response(
        headers={"Accept-Ranges": "bytes", "Content-Length": str(size)},
        media_type=content_type,
    )
