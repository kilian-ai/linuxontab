"""Source management + scan triggering."""
from __future__ import annotations

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..db import SessionLocal, get_db
from ..models import MediaItem, Source
from ..scanner import SCAN_STATUS, scan_source
from ..schemas import SourceCreate, SourceOut, SourceUpdate
from ..sources import build_source

router = APIRouter(prefix="/api/sources", tags=["sources"])


def _to_out(db: Session, s: Source) -> SourceOut:
    count = db.scalar(
        select(func.count(MediaItem.id)).where(MediaItem.source_id == s.id)
    )
    return SourceOut(
        id=s.id,
        name=s.name,
        kind=s.kind,
        path=s.path,
        smb_host=s.smb_host,
        smb_share=s.smb_share,
        smb_username=s.smb_username,
        has_password=bool(s.smb_password),
        last_scanned_at=s.last_scanned_at.isoformat() if s.last_scanned_at else None,
        item_count=count or 0,
    )


@router.get("", response_model=list[SourceOut])
def list_sources(db: Session = Depends(get_db)):
    return [_to_out(db, s) for s in db.scalars(select(Source).order_by(Source.id))]


@router.post("", response_model=SourceOut)
def create_source(payload: SourceCreate, db: Session = Depends(get_db)):
    if payload.kind not in ("local", "smb"):
        raise HTTPException(400, "kind must be 'local' or 'smb'")
    if payload.kind == "smb" and not (payload.smb_host and payload.smb_share):
        raise HTTPException(400, "smb sources require smb_host and smb_share")
    s = Source(**payload.model_dump())
    db.add(s)
    db.commit()
    db.refresh(s)
    return _to_out(db, s)


@router.patch("/{source_id}", response_model=SourceOut)
def update_source(source_id: int, payload: SourceUpdate, db: Session = Depends(get_db)):
    s = db.get(Source, source_id)
    if not s:
        raise HTTPException(404, "source not found")
    # Only apply fields the client actually sent.
    data = payload.model_dump(exclude_unset=True)
    # An empty password field means "leave the existing password unchanged".
    if not data.get("smb_password"):
        data.pop("smb_password", None)
    for field, value in data.items():
        setattr(s, field, value)
    db.commit()
    db.refresh(s)
    return _to_out(db, s)


@router.delete("/{source_id}")
def delete_source(source_id: int, db: Session = Depends(get_db)):
    s = db.get(Source, source_id)
    if not s:
        raise HTTPException(404, "source not found")
    db.delete(s)
    db.commit()
    return {"ok": True}


@router.post("/{source_id}/test")
def test_source(source_id: int, db: Session = Depends(get_db)):
    """Verify a source is reachable (SMB auth + share, or local path exists)."""
    s = db.get(Source, source_id)
    if not s:
        raise HTTPException(404, "source not found")
    try:
        message = build_source(s).test()
        return {"ok": True, "message": message}
    except Exception as e:
        return {"ok": False, "error": str(e) or e.__class__.__name__}


def _run_scan(source_id: int):
    """Background task: uses its own DB session."""
    db = SessionLocal()
    try:
        source = db.get(Source, source_id)
        if source:
            scan_source(db, source)
    except Exception as e:  # never leave the status stuck on "scanning"
        prev = SCAN_STATUS.get(source_id, {})
        SCAN_STATUS[source_id] = {
            "state": "error",
            "error": str(e) or e.__class__.__name__,
            "found": prev.get("found", 0),
            "added": prev.get("added", 0),
            "matched": prev.get("matched", 0),
        }
    finally:
        db.close()


@router.post("/{source_id}/scan")
def scan(source_id: int, background: BackgroundTasks, db: Session = Depends(get_db)):
    s = db.get(Source, source_id)
    if not s:
        raise HTTPException(404, "source not found")
    if SCAN_STATUS.get(source_id, {}).get("state") == "scanning":
        raise HTTPException(409, "scan already in progress")
    SCAN_STATUS[source_id] = {"state": "scanning", "found": 0, "added": 0, "matched": 0}
    background.add_task(_run_scan, source_id)
    return {"ok": True, "status": SCAN_STATUS[source_id]}


@router.get("/{source_id}/scan")
def scan_status(source_id: int):
    return SCAN_STATUS.get(source_id, {"state": "idle"})
