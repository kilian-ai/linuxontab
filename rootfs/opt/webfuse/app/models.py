"""ORM models: media sources and discovered library items."""
from datetime import datetime
from typing import Optional

from sqlalchemy import (
    JSON,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


class Source(Base):
    """A place to scan for media: a local folder or an SMB share."""

    __tablename__ = "sources"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    kind: Mapped[str] = mapped_column(String(20))  # "local" | "smb"

    # local: filesystem path. smb: root path within the share (e.g. "Movies").
    path: Mapped[str] = mapped_column(String(1000), default="")

    # SMB connection details (unused for local sources).
    smb_host: Mapped[Optional[str]] = mapped_column(String(255), default=None)
    smb_share: Mapped[Optional[str]] = mapped_column(String(255), default=None)
    smb_username: Mapped[Optional[str]] = mapped_column(String(255), default=None)
    smb_password: Mapped[Optional[str]] = mapped_column(String(255), default=None)
    smb_domain: Mapped[Optional[str]] = mapped_column(String(255), default=None)

    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())
    last_scanned_at: Mapped[Optional[datetime]] = mapped_column(DateTime, default=None)

    items: Mapped[list["MediaItem"]] = relationship(
        back_populates="source", cascade="all, delete-orphan"
    )


class MediaItem(Base):
    """A discovered movie, or one episode of a show.

    For movies, `media_type == "movie"`. For episodes, `media_type == "episode"`
    and the show-level metadata (poster, title) is duplicated onto the row so the
    frontend can group by `show_tmdb_id` without extra joins.
    """

    __tablename__ = "media_items"
    __table_args__ = (UniqueConstraint("source_id", "rel_path", name="uq_source_relpath"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    source_id: Mapped[int] = mapped_column(ForeignKey("sources.id"))
    source: Mapped["Source"] = relationship(back_populates="items")

    # Location within the source (relative path, POSIX-style separators).
    rel_path: Mapped[str] = mapped_column(String(2000))
    file_size: Mapped[int] = mapped_column(Integer, default=0)
    container: Mapped[str] = mapped_column(String(20), default="")  # extension w/o dot

    media_type: Mapped[str] = mapped_column(String(20))  # "movie" | "episode"

    # Parsed-from-filename fields (always present).
    parsed_title: Mapped[str] = mapped_column(String(500))
    year: Mapped[Optional[int]] = mapped_column(Integer, default=None)
    season: Mapped[Optional[int]] = mapped_column(Integer, default=None)
    episode: Mapped[Optional[int]] = mapped_column(Integer, default=None)

    # TMDB-enriched fields (null until matched).
    tmdb_id: Mapped[Optional[int]] = mapped_column(Integer, default=None)
    show_tmdb_id: Mapped[Optional[int]] = mapped_column(Integer, default=None)
    title: Mapped[Optional[str]] = mapped_column(String(500), default=None)
    overview: Mapped[Optional[str]] = mapped_column(Text, default=None)
    poster_path: Mapped[Optional[str]] = mapped_column(String(500), default=None)
    backdrop_path: Mapped[Optional[str]] = mapped_column(String(500), default=None)
    rating: Mapped[Optional[float]] = mapped_column(default=None)
    release_date: Mapped[Optional[str]] = mapped_column(String(20), default=None)
    runtime: Mapped[Optional[int]] = mapped_column(Integer, default=None)
    genres: Mapped[Optional[list]] = mapped_column(JSON, default=None)
    cast: Mapped[Optional[list]] = mapped_column(JSON, default=None)

    matched: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.now())

    # ffprobe-detected codecs (null until probed).
    video_codec: Mapped[Optional[str]] = mapped_column(String(40), default=None)
    audio_codec: Mapped[Optional[str]] = mapped_column(String(40), default=None)
    probed: Mapped[bool] = mapped_column(default=False)

    # BitTorrent link: set while (or after) the file arrives via Transmission.
    torrent_hash: Mapped[Optional[str]] = mapped_column(String(64), default=None)
    downloading: Mapped[bool] = mapped_column(default=False)

    # Watch progress / resume.
    position_seconds: Mapped[float] = mapped_column(default=0.0)
    duration_seconds: Mapped[float] = mapped_column(default=0.0)
    watched: Mapped[bool] = mapped_column(default=False)
    last_watched_at: Mapped[Optional[datetime]] = mapped_column(DateTime, default=None)

    @property
    def filename(self) -> str:
        return self.rel_path.rsplit("/", 1)[-1]
