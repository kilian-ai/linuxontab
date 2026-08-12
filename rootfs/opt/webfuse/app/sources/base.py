"""Abstract file source: uniform listing + range reads for local and SMB."""
from __future__ import annotations

from dataclasses import dataclass
from typing import IO, Iterator


@dataclass
class RemoteFile:
    rel_path: str  # POSIX-style path relative to the source root
    size: int


class FileSource:
    """Interface implemented by LocalSource and SmbSource."""

    def iter_files(self) -> Iterator[RemoteFile]:
        """Yield every file under the source root, recursively."""
        raise NotImplementedError

    def open(self, rel_path: str) -> IO[bytes]:
        """Open a file for binary reading; the returned object supports seek()."""
        raise NotImplementedError

    def size(self, rel_path: str) -> int:
        raise NotImplementedError

    def local_path(self, rel_path: str):
        """Return a real filesystem path if the file is local, else None.

        Lets ffmpeg read (and seek) local files directly; remote sources
        return None and are piped to ffmpeg via stdin instead.
        """
        return None

    def test(self) -> str:
        """Verify the source is reachable/valid; return a status string or raise."""
        raise NotImplementedError

    def siblings(self, rel_path: str) -> list[str]:
        """Filenames in the same directory as rel_path (for sidecar subtitles)."""
        return []
