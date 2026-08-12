"""SQLAlchemy engine, session factory, and Base."""
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import DATABASE_URL

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False},
    future=True,
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


class Base(DeclarativeBase):
    pass


def get_db():
    """FastAPI dependency yielding a scoped session."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db():
    from . import models  # noqa: F401  (register models)

    Base.metadata.create_all(bind=engine)
    _migrate()


# Columns added after the initial schema, applied to existing SQLite DBs.
_ADDED_COLUMNS = {
    "media_items": {
        "video_codec": "VARCHAR(40)",
        "audio_codec": "VARCHAR(40)",
        "probed": "BOOLEAN DEFAULT 0",
        "torrent_hash": "VARCHAR(64)",
        "downloading": "BOOLEAN DEFAULT 0",
        "position_seconds": "FLOAT DEFAULT 0",
        "duration_seconds": "FLOAT DEFAULT 0",
        "watched": "BOOLEAN DEFAULT 0",
        "last_watched_at": "DATETIME",
    },
}


def _migrate():
    """Add any missing columns to existing tables (lightweight SQLite migration)."""
    insp = inspect(engine)
    with engine.begin() as conn:
        for table, cols in _ADDED_COLUMNS.items():
            if not insp.has_table(table):
                continue
            existing = {c["name"] for c in insp.get_columns(table)}
            for name, ddl in cols.items():
                if name not in existing:
                    conn.execute(text(f'ALTER TABLE {table} ADD COLUMN {name} {ddl}'))
