"""WebFuse backend — FastAPI application."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import TMDB_API_KEY, TMDB_IMAGE_BASE
from .db import init_db
from .routers import (
    hls, library, playback, progress, sources, stream, subtitles, torrents,
)
from .transcode import ffmpeg_available, stop_all

app = FastAPI(title="WebFuse", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["Content-Range", "Accept-Ranges", "Content-Length"],
)


def _seed_sources():
    """Insert pre-configured sources from /opt/webfuse/seed_sources.json (if any).

    Idempotent — a source already present (same kind/host/share/path) is left
    alone — so it's safe to re-run on every startup and survives a DB reset.
    """
    import json
    from .db import SessionLocal
    from .models import Source

    seed_path = Path("/opt/webfuse/seed_sources.json")
    if not seed_path.exists():
        return
    try:
        entries = json.loads(seed_path.read_text())
    except Exception:
        return
    db = SessionLocal()
    try:
        for e in entries:
            if db.query(Source).filter(
                Source.kind == e.get("kind"),
                Source.smb_host == e.get("smb_host"),
                Source.smb_share == e.get("smb_share"),
                Source.path == e.get("path", ""),
            ).first():
                continue
            db.add(Source(
                name=e.get("name", "Seeded"),
                kind=e.get("kind", "local"),
                path=e.get("path", ""),
                smb_host=e.get("smb_host"),
                smb_share=e.get("smb_share"),
                smb_username=e.get("smb_username"),
                smb_password=e.get("smb_password"),
                smb_domain=e.get("smb_domain"),
            ))
        db.commit()
    finally:
        db.close()


@app.on_event("startup")
def _startup():
    init_db()
    _seed_sources()


@app.on_event("shutdown")
def _shutdown():
    stop_all()  # kill any running ffmpeg processes and clean temp segments


@app.get("/api/config")
def get_config():
    return {
        "tmdb_enabled": bool(TMDB_API_KEY),
        "transcode_available": ffmpeg_available(),
        "image_base": TMDB_IMAGE_BASE,
        "poster_size": "w500",
        "backdrop_size": "w1280",
        "profile_size": "w185",
    }


@app.get("/api/health")
def health():
    return {"ok": True}


app.include_router(sources.router)
app.include_router(library.router)
app.include_router(stream.router)
app.include_router(hls.router)
app.include_router(playback.router)
app.include_router(subtitles.router)
app.include_router(progress.router)
app.include_router(torrents.router)

# Serve the built frontend if it exists (production single-origin deployment).
_dist = Path(__file__).resolve().parent.parent.parent / "frontend" / "dist"
if _dist.is_dir():

    class SpaStaticFiles(StaticFiles):
        """Fall back to index.html for client-side routes like /shows, /play/7."""

        async def get_response(self, path, scope):
            from starlette.exceptions import HTTPException as StarletteHTTPException

            try:
                return await super().get_response(path, scope)
            except StarletteHTTPException as e:
                if e.status_code == 404:
                    return await super().get_response("index.html", scope)
                raise

    app.mount("/", SpaStaticFiles(directory=_dist, html=True), name="frontend")
