"""Local filesystem source."""
from __future__ import annotations

import os
from pathlib import Path
from typing import IO, Iterator

from ..config import IGNORE_DIRS, VIDEO_EXTENSIONS
from .base import FileSource, RemoteFile


class LocalSource(FileSource):
    def __init__(self, root: str):
        self.root = Path(root).expanduser().resolve()

    def iter_files(self) -> Iterator[RemoteFile]:
        for dirpath, dirs, files in os.walk(self.root):
            # Prune junk/dev directories and hidden dirs in place.
            dirs[:] = [d for d in dirs if d not in IGNORE_DIRS and not d.startswith(".")]
            for name in files:
                if Path(name).suffix.lower() not in VIDEO_EXTENSIONS:
                    continue
                full = Path(dirpath) / name
                try:
                    size = full.stat().st_size
                except OSError:
                    continue
                rel = full.relative_to(self.root).as_posix()
                yield RemoteFile(rel_path=rel, size=size)

    def _resolve(self, rel_path: str) -> Path:
        # Guard against path traversal outside the root.
        target = (self.root / rel_path).resolve()
        if not str(target).startswith(str(self.root)):
            raise PermissionError("path escapes source root")
        # While a torrent is still downloading, Transmission stores the file
        # with a ".part" suffix; fall back to it so in-progress files stream.
        if not target.exists():
            part = target.with_name(target.name + ".part")
            if part.exists():
                return part
        return target

    def open(self, rel_path: str) -> IO[bytes]:
        return open(self._resolve(rel_path), "rb")

    def size(self, rel_path: str) -> int:
        return self._resolve(rel_path).stat().st_size

    def local_path(self, rel_path: str) -> str:
        return str(self._resolve(rel_path))

    def test(self) -> str:
        if not self.root.exists():
            raise FileNotFoundError(f"path does not exist: {self.root}")
        if not self.root.is_dir():
            raise NotADirectoryError(f"not a directory: {self.root}")
        return f"OK — {self.root}"

    def siblings(self, rel_path: str) -> list[str]:
        parent = self._resolve(rel_path).parent
        try:
            return [p.name for p in parent.iterdir() if p.is_file()]
        except OSError:
            return []
