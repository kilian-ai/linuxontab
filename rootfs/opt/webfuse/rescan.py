#!/usr/bin/env python3
"""Rescan every source in-process (with TMDB enrichment when a key is set).

    python3 /opt/webfuse/rescan.py

Runs scan_source() directly — the /api/sources/{id}/scan endpoint defers to
FastAPI BackgroundTasks, which is unreliable on the wasm guest. Makes sure the
bundled /opt/webfuse/testmedia source exists. Reads /opt/webfuse/.env like
the server does, so `spiel-demo key <KEY>` + this = posters.
"""
import sys
sys.path.insert(0, "/opt/webfuse-libs")
sys.path.insert(0, "/opt/webfuse")

from app.config import TMDB_API_KEY                # noqa: E402
from app.db import SessionLocal, init_db           # noqa: E402
from app.models import Source                      # noqa: E402
from app.scanner import scan_source                # noqa: E402

MEDIA = "/opt/webfuse/testmedia"
init_db()
db = SessionLocal()
try:
    if not db.query(Source).filter(Source.path == MEDIA).first():
        db.add(Source(name="Test Media", kind="local", path=MEDIA)); db.commit()
    print("tmdb:", "enabled" if TMDB_API_KEY else "no key (posters off)")
    for src in db.query(Source).all():
        try:
            print("scan %s (%s %s):" % (src.name, src.kind, src.path), scan_source(db, src))
        except Exception as e:
            print("scan %s failed: %s" % (src.name, e))
finally:
    db.close()
