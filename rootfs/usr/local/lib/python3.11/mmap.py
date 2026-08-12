"""Minimal pure-Python mmap shim for the LinuxOnTab wasm kernel (nommu).

The wasm32 musl port has no real mmap(); this provides the small subset that
common libraries (e.g. pip's vendored cachecontrol) actually use: anonymous
maps as growable in-memory buffers, and read-only file maps loaded eagerly.

mmap subclasses bytearray so instances satisfy the buffer protocol —
`memoryview(m)`, `bytes(m)`, and writing an mmap straight to a socket all
work (pip 23+ does `memoryview(mmap_obj)` when streaming downloads; a plain
object shim made every `pip install` fail with a TypeError).
"""

import os

ACCESS_DEFAULT = 0
ACCESS_READ = 1
ACCESS_WRITE = 2
ACCESS_COPY = 3

PAGESIZE = 65536
ALLOCATIONGRANULARITY = PAGESIZE

MAP_SHARED = 1
MAP_PRIVATE = 2
MAP_ANONYMOUS = MAP_ANON = 32
PROT_READ = 1
PROT_WRITE = 2
PROT_EXEC = 4

error = OSError


class mmap(bytearray):
    """Anonymous maps -> zero-filled buffer; file maps -> eager read.

    The bytearray IS the mapped content, so the buffer protocol comes from
    the base type. close() only marks the map invalid (emptying the buffer
    would raise BufferError if a memoryview is still exported).
    """

    def __init__(self, fileno, length, flags=MAP_SHARED, prot=PROT_READ | PROT_WRITE,
                 access=ACCESS_DEFAULT, offset=0):
        if fileno == -1:
            super().__init__(length)          # zero-filled anonymous map
        else:
            size = os.fstat(fileno).st_size
            n = (size - offset) if length == 0 else length
            super().__init__(os.pread(fileno, n, offset))
        self._closed = False
        self._pos = 0
        self._access = access
        self._fixed = fileno != -1 and access in (ACCESS_READ, ACCESS_COPY)

    # -- core file-like API -------------------------------------------------
    def _check(self):
        if self._closed:
            raise ValueError("mmap closed or invalid")

    def close(self):
        self._closed = True

    @property
    def closed(self):
        return self._closed

    def read(self, n=None):
        self._check()
        if n is None or n < 0:
            n = len(self) - self._pos
        data = bytes(self[self._pos:self._pos + n])
        self._pos += len(data)
        return data

    def read_byte(self):
        self._check()
        if self._pos >= len(self):
            raise ValueError("read byte out of range")
        b = bytearray.__getitem__(self, self._pos)
        self._pos += 1
        return b

    def readline(self):
        self._check()
        i = self.find(b"\n", self._pos)
        end = len(self) if i < 0 else i + 1
        data = bytes(self[self._pos:end])
        self._pos = end
        return data

    def write(self, data):
        self._check()
        if self._access == ACCESS_READ:
            raise TypeError("mmap can't modify a readonly memory map")
        data = bytes(data)
        end = self._pos + len(data)
        if end > len(self):
            if self._fixed:
                raise ValueError("data out of range")
            self.extend(b"\x00" * (end - len(self)))
        self[self._pos:end] = data
        self._pos = end
        return len(data)

    def write_byte(self, byte):
        self.write(bytes([byte]))

    def seek(self, pos, whence=0):
        self._check()
        if whence == 0:
            new = pos
        elif whence == 1:
            new = self._pos + pos
        elif whence == 2:
            new = len(self) + pos
        else:
            raise ValueError("unknown seek type")
        if new < 0:
            raise ValueError("seek out of range")
        self._pos = new

    def tell(self):
        self._check()
        return self._pos

    def size(self):
        self._check()
        return len(self)

    def resize(self, newsize):
        self._check()
        if self._fixed:
            raise TypeError("mmap can't resize a readonly memory map")
        cur = len(self)
        if newsize < cur:
            del self[newsize:]
        else:
            self.extend(b"\x00" * (newsize - cur))

    def flush(self, offset=0, size=None):
        self._check()
        return 0

    def move(self, dest, src, count):
        self._check()
        self[dest:dest + count] = self[src:src + count]

    # -- overrides ----------------------------------------------------------
    def __getitem__(self, index):
        # CPython mmap returns bytes for slices (bytearray would return
        # bytearray) — keep that contract for callers that type-check.
        v = bytearray.__getitem__(self, index)
        return bytes(v) if isinstance(index, slice) else v

    def __setitem__(self, index, value):
        if self._access == ACCESS_READ:
            raise TypeError("mmap can't modify a readonly memory map")
        bytearray.__setitem__(self, index, value)

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *exc):
        self.close()
