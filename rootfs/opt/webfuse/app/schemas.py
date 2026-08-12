"""Pydantic schemas for request/response bodies."""
from typing import Optional

from pydantic import BaseModel


class SourceCreate(BaseModel):
    name: str
    kind: str  # "local" | "smb"
    path: str = ""
    smb_host: Optional[str] = None
    smb_share: Optional[str] = None
    smb_username: Optional[str] = None
    smb_password: Optional[str] = None
    smb_domain: Optional[str] = None


class SourceUpdate(BaseModel):
    """Partial update — only fields that are sent are applied."""
    name: Optional[str] = None
    path: Optional[str] = None
    smb_host: Optional[str] = None
    smb_share: Optional[str] = None
    smb_username: Optional[str] = None
    smb_password: Optional[str] = None  # empty/omitted → keep existing password
    smb_domain: Optional[str] = None


class SourceOut(BaseModel):
    id: int
    name: str
    kind: str
    path: str
    smb_host: Optional[str] = None
    smb_share: Optional[str] = None
    smb_username: Optional[str] = None
    has_password: bool = False
    last_scanned_at: Optional[str] = None
    item_count: int = 0

    class Config:
        from_attributes = True


class MediaOut(BaseModel):
    id: int
    source_id: int
    media_type: str
    parsed_title: str
    title: Optional[str] = None
    year: Optional[int] = None
    season: Optional[int] = None
    episode: Optional[int] = None
    overview: Optional[str] = None
    poster_path: Optional[str] = None
    backdrop_path: Optional[str] = None
    rating: Optional[float] = None
    release_date: Optional[str] = None
    runtime: Optional[int] = None
    genres: Optional[list] = None
    cast: Optional[list] = None
    container: str = ""
    filename: Optional[str] = None
    matched: bool = False
    downloading: bool = False
    torrent_hash: Optional[str] = None
    position_seconds: float = 0.0
    duration_seconds: float = 0.0
    watched: bool = False

    class Config:
        from_attributes = True


class ShowOut(BaseModel):
    """A grouped TV show with its episodes."""
    show_tmdb_id: Optional[int]
    title: str
    poster_path: Optional[str] = None
    backdrop_path: Optional[str] = None
    overview: Optional[str] = None
    rating: Optional[float] = None
    genres: Optional[list] = None
    cast: Optional[list] = None
    episode_count: int = 0
