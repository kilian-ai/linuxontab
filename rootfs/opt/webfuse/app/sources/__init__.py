"""Source factory: turn a Source DB row into a FileSource implementation."""
from ..models import Source
from .base import FileSource, RemoteFile
from .local import LocalSource

# SMB needs smbprotocol -> cryptography (Rust), unavailable on the wasm guest.
try:
    from .smb import SmbSource
except ImportError:  # pragma: no cover
    SmbSource = None

__all__ = ["FileSource", "RemoteFile", "build_source"]


def build_source(row: Source) -> FileSource:
    if row.kind == "local":
        return LocalSource(row.path)
    if row.kind == "smb":
        if SmbSource is None:
            raise ValueError("SMB sources are unavailable on this platform")
        return SmbSource(
            host=row.smb_host or "",
            share=row.smb_share or "",
            root=row.path or "",
            username=row.smb_username,
            password=row.smb_password,
            domain=row.smb_domain,
        )
    raise ValueError(f"unknown source kind: {row.kind}")
