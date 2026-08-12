"""Transmission RPC client + Torznab search (optional BitTorrent integration)."""
from __future__ import annotations

import base64
import xml.etree.ElementTree as ET
from typing import Optional

import httpx

from .config import (
    PROWLARR_APIKEY,
    PROWLARR_URL,
    TORZNAB_APIKEY,
    TORZNAB_URL,
    TRANSMISSION_URL,
)


class TransmissionError(RuntimeError):
    pass


class TransmissionClient:
    """Minimal Transmission RPC client (handles the 409 session-id dance)."""

    def __init__(self, url: str = TRANSMISSION_URL):
        self.url = url
        self._session_id = ""
        self._client = httpx.Client(timeout=15.0)

    def _call(self, method: str, arguments: Optional[dict] = None) -> dict:
        payload = {"method": method, "arguments": arguments or {}}
        for attempt in (1, 2):
            try:
                r = self._client.post(
                    self.url,
                    json=payload,
                    headers={"X-Transmission-Session-Id": self._session_id},
                )
            except httpx.HTTPError as e:
                raise TransmissionError(f"Transmission unreachable at {self.url}: {e}")
            if r.status_code == 409 and attempt == 1:
                self._session_id = r.headers.get("X-Transmission-Session-Id", "")
                continue
            if r.status_code != 200:
                raise TransmissionError(f"Transmission RPC HTTP {r.status_code}")
            data = r.json()
            if data.get("result") != "success":
                raise TransmissionError(f"Transmission: {data.get('result')}")
            return data.get("arguments", {})
        raise TransmissionError("Transmission: session negotiation failed")

    def ping(self) -> dict:
        args = self._call("session-get")
        return {
            "version": args.get("version"),
            "download_dir": args.get("download-dir"),
        }

    def add_magnet(self, link: str, download_dir: Optional[str] = None) -> dict:
        # Resolve indexer download URLs (which may redirect to a magnet or serve
        # raw .torrent bytes) before handing to Transmission — Transmission does
        # not follow the redirects that Prowlarr/Torznab download links use.
        kind, value = _resolve_link(link)
        arguments: dict = {}
        if kind == "magnet":
            arguments["filename"] = value
        else:  # raw .torrent bytes
            arguments["metainfo"] = base64.b64encode(value).decode("ascii")
        if download_dir:
            arguments["download-dir"] = download_dir
        args = self._call("torrent-add", arguments)
        info = args.get("torrent-added") or args.get("torrent-duplicate")
        if not info:
            raise TransmissionError("Transmission accepted the request but returned no torrent")
        # Best-effort sequential download (Transmission >= 4.0) so the front of
        # the file arrives first and can be streamed while downloading.
        try:
            self._call(
                "torrent-set",
                {"ids": [info["id"]], "sequential_download": True},
            )
        except TransmissionError:
            pass
        return {"id": info["id"], "name": info.get("name"), "hash": info.get("hashString")}

    def list_torrents(self) -> list[dict]:
        fields = [
            "id", "name", "percentDone", "status", "rateDownload", "rateUpload",
            "totalSize", "downloadDir", "eta", "peersSendingToUs", "files",
            "errorString",
        ]
        args = self._call("torrent-get", {"fields": fields})
        out = []
        for t in args.get("torrents", []):
            largest = None
            for f in t.get("files", []) or []:
                if largest is None or f["length"] > largest["length"]:
                    largest = f
            out.append(
                {
                    "id": t["id"],
                    "name": t["name"],
                    "progress": round(t.get("percentDone", 0) * 100, 1),
                    "status": _status_name(t.get("status")),
                    "rate_down": t.get("rateDownload", 0),
                    "peers": t.get("peersSendingToUs", 0),
                    "size": t.get("totalSize", 0),
                    "eta": t.get("eta", -1),
                    "download_dir": t.get("downloadDir"),
                    "main_file": largest["name"] if largest else None,
                    "error": t.get("errorString") or None,
                }
            )
        return out

    def detail(self, ids=None) -> list[dict]:
        """Full per-torrent info incl. piece bitfield and files."""
        fields = [
            "id", "name", "hashString", "percentDone", "status",
            "pieceCount", "pieceSize", "pieces", "files", "downloadDir",
            "sequential_download", "totalSize", "rateDownload", "eta",
            "peersSendingToUs", "errorString",
        ]
        args = {"fields": fields}
        if ids is not None:
            args["ids"] = ids
        return self._call("torrent-get", args).get("torrents", [])

    def set_sequential(self, torrent_id: int, on: bool = True):
        self._call("torrent-set", {"ids": [torrent_id], "sequential_download": on})

    def remove(self, torrent_id: int, delete_data: bool = False):
        self._call(
            "torrent-remove",
            {"ids": [torrent_id], "delete-local-data": bool(delete_data)},
        )

    def close(self):
        self._client.close()


def _resolve_link(link: str) -> tuple[str, object]:
    """Resolve a magnet/torrent link to ('magnet', uri) or ('torrent', bytes).

    Follows HTTP redirects manually because they often point at a magnet: URI
    (a non-HTTP scheme that httpx won't auto-follow).
    """
    if link.startswith("magnet:"):
        return ("magnet", link)
    url = link
    with httpx.Client(timeout=30.0) as c:
        for _ in range(6):
            r = c.get(url, follow_redirects=False)
            if r.status_code in (301, 302, 303, 307, 308):
                loc = r.headers.get("location", "")
                if loc.startswith("magnet:"):
                    return ("magnet", loc)
                if not loc:
                    raise TransmissionError("download link redirect had no location")
                url = str(httpx.URL(url).join(loc))
                continue
            r.raise_for_status()
            body = r.content
            if body[:7].lstrip().startswith(b"magnet:"):
                return ("magnet", body.decode("utf-8", "replace").strip())
            return ("torrent", body)
    raise TransmissionError("too many redirects resolving download link")


def _status_name(code) -> str:
    return {
        0: "stopped", 1: "check-wait", 2: "checking",
        3: "download-wait", 4: "downloading", 5: "seed-wait", 6: "seeding",
    }.get(code, "unknown")


VIDEO_EXTS = (".mp4", ".m4v", ".mkv", ".webm", ".mov", ".avi", ".m2ts", ".mpg", ".mpeg", ".wmv", ".flv")

# Ignore video files below this size (sample clips) when enumerating a torrent.
MIN_TORRENT_VIDEO = 50 * 1024 * 1024  # 50 MiB


def video_files(torrent: dict):
    """All sizable video files in a torrent as [(index, file_dict), ...].

    Handles season packs (many episode files in one torrent), skipping tiny
    sample clips.
    """
    out = [
        (i, f)
        for i, f in enumerate(torrent.get("files") or [])
        if f["name"].lower().endswith(VIDEO_EXTS) and f["length"] >= MIN_TORRENT_VIDEO
    ]
    return out


def main_video_file(torrent: dict):
    """Return (index, file_dict) of the largest video file in a torrent."""
    best = None
    for i, f in enumerate(torrent.get("files") or []):
        if not f["name"].lower().endswith(VIDEO_EXTS):
            continue
        if best is None or f["length"] > best[1]["length"]:
            best = (i, f)
    return best if best else (None, None)


def find_file_index(torrent: dict, rel_path: str):
    """Index of the torrent file matching a library item's rel_path (by name
    suffix), falling back to the largest video file."""
    files = torrent.get("files") or []
    tail = rel_path.replace("\\", "/")
    base = tail.rsplit("/", 1)[-1]
    # Prefer an exact suffix match, then a basename match.
    for i, f in enumerate(files):
        if f["name"].replace("\\", "/").endswith(tail):
            return i, f
    for i, f in enumerate(files):
        if f["name"].replace("\\", "/").rsplit("/", 1)[-1] == base:
            return i, f
    return main_video_file(torrent)


def _bit(data: bytes, i: int) -> int:
    return (data[i >> 3] >> (7 - (i & 7))) & 1 if (i >> 3) < len(data) else 0


def file_stream_info(torrent: dict, file_index: int, n_buckets: int = 120) -> dict:
    """Piece availability for one file: contiguous streamable prefix + a
    downsampled availability map for visualization."""
    files = torrent["files"]
    piece_size = torrent["pieceSize"]
    length = files[file_index]["length"]
    offset = sum(files[j]["length"] for j in range(file_index))

    pieces = base64.b64decode(torrent.get("pieces") or "")
    first = offset // piece_size
    last = (offset + length - 1) // piece_size
    total_pieces = last - first + 1

    # Contiguous available pieces from the file's first piece.
    contig = 0
    for p in range(first, last + 1):
        if _bit(pieces, p):
            contig += 1
        else:
            break
    streamable = max(0, min(length, (first + contig) * piece_size - offset))

    # Downsample piece availability into buckets for the UI.
    buckets = []
    if total_pieces <= n_buckets:
        buckets = [_bit(pieces, p) for p in range(first, last + 1)]
    else:
        per = total_pieces / n_buckets
        for b in range(n_buckets):
            p0 = first + int(b * per)
            p1 = first + int((b + 1) * per)
            p1 = max(p1, p0 + 1)
            got = sum(_bit(pieces, p) for p in range(p0, min(p1, last + 1)))
            buckets.append(round(got / (min(p1, last + 1) - p0), 3))

    done = files[file_index].get("bytesCompleted", 0)
    return {
        "size": length,
        "downloaded": done,
        "progress": round(done / length * 100, 1) if length else 0.0,
        "streamable_bytes": streamable,
        "streamable_fraction": round(streamable / length, 4) if length else 0.0,
        "complete": contig == total_pieces,
        "buckets": buckets,
    }


# --- Search ----------------------------------------------------------------

def search_provider() -> Optional[str]:
    if PROWLARR_URL:
        return "prowlarr"
    if TORZNAB_URL:
        return "torznab"
    return None


def search_configured() -> bool:
    return search_provider() is not None


def search_torrents(query: str, limit: int = 30) -> list[dict]:
    provider = search_provider()
    if provider == "prowlarr":
        return prowlarr_search(query, limit)
    if provider == "torznab":
        return torznab_search(query, limit)
    raise RuntimeError("no torrent indexer configured")


def prowlarr_search(query: str, limit: int = 30) -> list[dict]:
    """Aggregate search across all indexers configured in Prowlarr."""
    with httpx.Client(timeout=45.0) as c:
        r = c.get(
            f"{PROWLARR_URL}/api/v1/search",
            params={"query": query, "type": "search", "limit": limit},
            headers={"X-Api-Key": PROWLARR_APIKEY},
        )
        r.raise_for_status()
        items = r.json()

    results = []
    for it in items:
        link = it.get("magnetUrl") or it.get("downloadUrl")
        if not link:
            continue
        results.append(
            {
                "title": it.get("title", "?"),
                "size": it.get("size", 0),
                "seeders": it.get("seeders", 0),
                "peers": it.get("leechers", 0),
                "indexer": it.get("indexer"),
                "link": link,
            }
        )
    results.sort(key=lambda x: x["seeders"], reverse=True)
    return results[:limit]


# --- Torznab search --------------------------------------------------------

def torznab_configured() -> bool:
    return bool(TORZNAB_URL)


def torznab_search(query: str, limit: int = 30) -> list[dict]:
    """Query a Torznab endpoint (Jackett/Prowlarr) and return magnet results."""
    if not torznab_configured():
        raise RuntimeError("no Torznab indexer configured (set TORZNAB_URL / TORZNAB_APIKEY)")
    params = {"t": "search", "q": query, "limit": limit}
    if TORZNAB_APIKEY:
        params["apikey"] = TORZNAB_APIKEY
    with httpx.Client(timeout=30.0, follow_redirects=True) as c:
        r = c.get(TORZNAB_URL, params=params)
        r.raise_for_status()
        root = ET.fromstring(r.text)

    ns = {"torznab": "http://torznab.com/schemas/2015/feed"}
    results = []
    for item in root.iter("item"):
        title = item.findtext("title") or "?"
        size = int(item.findtext("size") or 0)
        magnet = None
        seeders = peers = 0
        for attr in item.findall("torznab:attr", ns):
            name, value = attr.get("name"), attr.get("value")
            if name == "magneturl":
                magnet = value
            elif name == "seeders":
                seeders = int(value or 0)
            elif name == "peers":
                peers = int(value or 0)
        if not magnet:
            link = item.findtext("link") or ""
            if link.startswith("magnet:"):
                magnet = link
            else:
                enclosure = item.find("enclosure")
                url = enclosure.get("url") if enclosure is not None else ""
                if url.startswith("magnet:"):
                    magnet = url
        if magnet:
            results.append(
                {"title": title, "size": size, "seeders": seeders, "peers": peers,
                 "indexer": None, "link": magnet}
            )
    results.sort(key=lambda x: x["seeders"], reverse=True)
    return results
