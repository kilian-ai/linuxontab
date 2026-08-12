#!/usr/bin/env python3
"""Register /opt/webfuse/testmedia as a source and scan it, in-process.

Run this once after starting run.sh so the library has content:

    python3 /opt/webfuse/scan_testmedia.py

We call scan_source() directly rather than POSTing /api/sources/{id}/scan
because that endpoint defers to FastAPI BackgroundTasks, which is unreliable
on the wasm guest. Safe to re-run — an existing source is reused and already
known items come back as added=0.
"""
import sys

sys.path.insert(0, "/opt/webfuse-libs")
sys.path.insert(0, "/opt/webfuse")

from app.db import SessionLocal, init_db          # noqa: E402
from app.models import Source                      # noqa: E402
from app.scanner import scan_source                # noqa: E402

MEDIA = "/opt/webfuse/testmedia"

init_db()
db = SessionLocal()
try:
    src = db.query(Source).filter(Source.path == MEDIA).first()
    if not src:
        src = Source(name="Test Media", kind="local", path=MEDIA)
        db.add(src)
        db.commit()
        db.refresh(src)
    print("source id=%s path=%s" % (src.id, src.path))
    print("scan:", scan_source(db, src))
finally:
    db.close()
