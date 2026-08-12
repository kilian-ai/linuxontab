"""SMB (CIFS) source backed by **pysmb** — pure Python (only needs pyasn1), so
it runs on the LinuxOnTab wasm guest. The previous implementation used
smbprotocol/smbclient, which pulls in the Rust `cryptography` package and can't
be built for wasm. pysmb does NTLM with hashlib + a bundled DES, so it works.

Reachability note: the wasm guest egresses through a WISP relay. The default
cloud relay can't route to a LAN SMB server, so the guest must be pointed at a
relay running inside the LAN (see ?wisp= in shell/wasm.html).
"""
from __future__ import annotations

import hashlib
import io
import os
import threading
from pathlib import PurePosixPath
from typing import IO, Iterator

from smb.SMBConnection import SMBConnection

from ..config import IGNORE_DIRS, VIDEO_EXTENSIONS
from .base import FileSource, RemoteFile

SMB_PORT = 445

# The WISP relay link the guest uses for SMB is fragile under many short-lived
# connections, and a video player fires a fresh HTTP range request every few
# seconds. So we cache to disk PROGRESSIVELY: a stream reads from SMB and
# appends to a contiguous-prefix cache (<h>.part) as it goes, serving already-
# cached bytes from disk and only touching SMB at the download frontier. Byte 0
# is available after the first chunk (playback starts immediately — no blocking
# on a full download), and once the prefix reaches the file size the .part is
# promoted to the final cache and all future reads are pure disk. Files above
# _CACHE_MAX fall back to live range reads over one reused connection.
_CACHE_DIR = os.environ.get("LOT_SMB_CACHE", "/opt/webfuse/data/smbcache")
_CACHE_MAX = int(os.environ.get("LOT_SMB_CACHE_MAX", str(1024 * 1024 * 1024)))  # 1 GB

# Serialize appends to a given .part file across overlapping range requests.
_part_locks: dict[str, "threading.Lock"] = {}
_part_locks_guard = threading.Lock()


def _part_lock(path: str) -> "threading.Lock":
    with _part_locks_guard:
        lk = _part_locks.get(path)
        if lk is None:
            lk = threading.Lock()
            _part_locks[path] = lk
        return lk


class _SmbFile(io.RawIOBase):
    """Seekable, read-only file over an SMB share via pysmb range reads.

    Each range request from the browser opens one of these; it holds a single
    SMBConnection and issues SMB2 READs at explicit offsets, so seek()/read()
    give real random access for video streaming.
    """

    def __init__(self, conn: SMBConnection, share: str, path: str, size: int):
        self._conn = conn
        self._share = share
        self._path = path
        self._size = size
        self._pos = 0

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        if whence == io.SEEK_SET:
            self._pos = offset
        elif whence == io.SEEK_CUR:
            self._pos += offset
        elif whence == io.SEEK_END:
            self._pos = self._size + offset
        if self._pos < 0:
            self._pos = 0
        return self._pos

    def tell(self) -> int:
        return self._pos

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            n = self._size - self._pos
        n = min(n, self._size - self._pos)
        if n <= 0:
            return b""
        buf = io.BytesIO()
        self._conn.retrieveFileFromOffset(
            self._share, self._path, buf, offset=self._pos, max_length=n
        )
        data = buf.getvalue()
        self._pos += len(data)
        return data

    def close(self) -> None:
        try:
            self._conn.close()
        except Exception:
            pass
        super().close()


class _ProgressiveSmbFile(io.RawIOBase):
    """Seekable reader that caches a contiguous prefix of the file to disk.

    read() serves bytes already in <part> from disk; bytes at the download
    frontier (pos == len(part)) are fetched from SMB and appended, extending the
    prefix; a seek ahead of the frontier reads live from SMB without caching (to
    avoid a hole). When the prefix reaches the file size, <part> is promoted to
    <final> and every later open() serves pure disk. The SMB connection is lazy
    and reused, so a straight play uses ONE connection for the whole file.
    """

    def __init__(self, source: "SmbSource", share: str, smb_path: str,
                 size: int, part_path: str, final_path: str):
        self._src = source
        self._share = share
        self._path = smb_path
        self._size = size
        self._part = part_path
        self._final = final_path
        self._pos = 0
        self._conn: SMBConnection | None = None
        self._lock = _part_lock(part_path)

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        if whence == io.SEEK_SET:
            self._pos = offset
        elif whence == io.SEEK_CUR:
            self._pos += offset
        elif whence == io.SEEK_END:
            self._pos = self._size + offset
        if self._pos < 0:
            self._pos = 0
        return self._pos

    def tell(self) -> int:
        return self._pos

    def _conn_get(self) -> SMBConnection:
        if self._conn is None:
            self._conn = self._src._connect()
        return self._conn

    def _smb_read(self, offset: int, length: int) -> bytes:
        buf = io.BytesIO()
        self._conn_get().retrieveFileFromOffset(
            self._share, self._path, buf, offset=offset, max_length=length
        )
        return buf.getvalue()

    def read(self, n: int = -1) -> bytes:
        if n is None or n < 0:
            n = self._size - self._pos
        n = min(n, self._size - self._pos)
        if n <= 0:
            return b""
        # Fully downloaded meanwhile → pure disk.
        if os.path.exists(self._final):
            with open(self._final, "rb") as f:
                f.seek(self._pos)
                data = f.read(n)
            self._pos += len(data)
            return data
        cached = os.path.getsize(self._part) if os.path.exists(self._part) else 0
        end = self._pos + n
        out = bytearray()
        # Serve the part already on disk.
        if self._pos < cached:
            with open(self._part, "rb") as f:
                f.seek(self._pos)
                out += f.read(min(n, cached - self._pos))
            self._pos += len(out)
            if self._pos >= end:
                return bytes(out)
        # Remaining bytes come from SMB.
        want = end - self._pos
        smb_data = self._smb_read(self._pos, want)
        # Extend the contiguous prefix if we're exactly at the frontier.
        with self._lock:
            if not os.path.exists(self._final):   # another reader may have finalized
                cur = os.path.getsize(self._part) if os.path.exists(self._part) else 0
                if self._pos == cur and smb_data:
                    with open(self._part, "ab") as f:
                        f.write(smb_data)
                    if os.path.getsize(self._part) >= self._size:
                        try:
                            os.replace(self._part, self._final)
                        except OSError:
                            pass
        out += smb_data
        self._pos += len(smb_data)
        return bytes(out)

    def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
        super().close()


class SmbSource(FileSource):
    def __init__(
        self,
        host: str,
        share: str,
        root: str = "",
        username: str | None = None,
        password: str | None = None,
        domain: str | None = None,
    ):
        self.host = host
        self.share = share
        self.root = root.strip("/")
        # No credentials → guest/anonymous (server must map bad users to guest).
        self.username = username or "guest"
        self.password = password or ""
        self.domain = domain or ""
        # NB: no eager connect here — build_source() constructs a SmbSource for
        # every request, so probing on __init__ would open an SMB connection per
        # HTTP call. Reachability is checked explicitly in test() / on scan.

    # ── connection + path helpers ────────────────────────────────────────────

    def _connect(self) -> SMBConnection:
        conn = SMBConnection(
            self.username,
            self.password,
            "webfuse",
            self.host or "server",
            domain=self.domain,
            use_ntlm_v2=True,
            is_direct_tcp=True,   # SMB over TCP/445, not NetBIOS/139
        )
        try:
            ok = conn.connect(self.host, SMB_PORT, timeout=20)
        except Exception as e:
            raise RuntimeError(f"SMB connection to {self.host} failed: {e}") from e
        if not ok:
            raise RuntimeError(
                f"SMB authentication to //{self.host}/{self.share} was rejected. "
                f"Add a username/password if the share isn't guest-accessible."
            )
        return conn

    def _smb_path(self, rel: str = "") -> str:
        """SMB path within the share, e.g. '/Movies/x.mkv' (root-prefixed)."""
        parts = []
        if self.root:
            parts += self.root.split("/")
        if rel:
            parts += rel.strip("/").split("/")
        return "/" + "/".join(p for p in parts if p)

    # ── FileSource interface ─────────────────────────────────────────────────

    def iter_files(self) -> Iterator[RemoteFile]:
        conn = self._connect()
        try:
            yield from self._walk(conn, self._smb_path(), "")
        finally:
            conn.close()

    def _walk(self, conn: SMBConnection, smb_dir: str, rel_prefix: str):
        try:
            entries = conn.listPath(self.share, smb_dir or "/")
        except Exception:
            return
        for e in entries:
            if e.filename in (".", ".."):
                continue
            rel = (rel_prefix + "/" + e.filename).lstrip("/")
            if e.isDirectory:
                if e.filename in IGNORE_DIRS or e.filename.startswith("."):
                    continue
                yield from self._walk(conn, smb_dir.rstrip("/") + "/" + e.filename, rel)
            else:
                if PurePosixPath(e.filename).suffix.lower() in VIDEO_EXTENSIONS:
                    yield RemoteFile(rel_path=rel, size=e.file_size)

    def _cache_path(self, rel_path: str) -> str:
        key = f"{self.host}|{self.share}|{self.root}|{rel_path}".encode()
        h = hashlib.sha1(key).hexdigest()[:16]
        return os.path.join(_CACHE_DIR, h + os.path.splitext(rel_path)[1])

    def open(self, rel_path: str) -> IO[bytes]:
        path = self._smb_path(rel_path)
        final = self._cache_path(rel_path)
        # Already fully cached → pure disk, no SMB at all.
        if os.path.exists(final):
            return open(final, "rb")
        size = self.size(rel_path)
        if 0 < size <= _CACHE_MAX:
            os.makedirs(_CACHE_DIR, exist_ok=True)
            return _ProgressiveSmbFile(self, self.share, path, size, final + ".part", final)
        # Very large file: live range reads over one reused SMB connection.
        return _SmbFile(self._connect(), self.share, path, size)

    def size(self, rel_path: str) -> int:
        # Prefer the local cache (no SMB round-trip) once fully downloaded.
        final = self._cache_path(rel_path)
        if os.path.exists(final):
            return os.path.getsize(final)
        conn = self._connect()
        try:
            return conn.getAttributes(self.share, self._smb_path(rel_path)).file_size
        finally:
            conn.close()

    def test(self) -> str:
        conn = self._connect()
        try:
            n = len(conn.listPath(self.share, self._smb_path() or "/"))
            return f"OK — connected to //{self.host}/{self.share}, {n} entries"
        finally:
            conn.close()

    def siblings(self, rel_path: str) -> list[str]:
        parent = rel_path.replace("\\", "/").rsplit("/", 1)[0] if "/" in rel_path else ""
        conn = self._connect()
        try:
            return [
                e.filename
                for e in conn.listPath(self.share, self._smb_path(parent) or "/")
                if not e.isDirectory
            ]
        except Exception:
            return []
        finally:
            conn.close()
