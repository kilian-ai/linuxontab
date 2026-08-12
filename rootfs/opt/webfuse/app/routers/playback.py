"""Playback decision: probe codecs (cached) and choose direct-play vs. HLS."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import MediaItem, Source
from ..probe import decide_playback, probe_codecs
from ..sources import build_source
from ..subtitles import list_tracks
from ..tracks import detect_intro, probe_streams
from .library import next_episode_item

router = APIRouter(prefix="/api/playback", tags=["playback"])


@router.get("/{item_id}")
def playback_info(item_id: int, db: Session = Depends(get_db)):
    item = db.get(MediaItem, item_id)
    if not item:
        raise HTTPException(404, "item not found")
    source = db.get(Source, item.source_id)
    if not source:
        raise HTTPException(404, "source not found")

    # Probe once and cache codecs on the row. A probe failure is non-fatal —
    # decide_playback falls back to the container heuristic. Skip probing while
    # downloading: ffprobe on a partial file can hang (its index may not have
    # arrived yet), and codecs shouldn't be cached from an incomplete file.
    if not item.probed and not item.downloading:
        try:
            codecs = probe_codecs(build_source(source), item.rel_path)
        except Exception:
            codecs = None
        if codecs:
            item.video_codec = codecs.get("video")
            item.audio_codec = codecs.get("audio")
        item.probed = True
        db.commit()

    decision = decide_playback(item.container, item.video_codec, item.audio_codec)

    # Audio + subtitle tracks (best-effort; empty while downloading or on SMB
    # where we can't cheaply probe).
    audio_tracks: list = []
    subtitle_tracks: list = []
    intro = None
    local = None
    total_duration = item.duration_seconds or 0.0
    try:
        if not item.downloading:
            local = build_source(source).local_path(item.rel_path)
            if local:
                probed = probe_streams(local)
                audio_tracks = probed["audio"]
                if probed.get("duration"):
                    total_duration = probed["duration"]
            subtitle_tracks = list_tracks(item, source)
    except Exception:
        pass

    try:
        intro = detect_intro(local, item.media_type == "episode")
    except Exception:
        intro = None

    nxt = next_episode_item(db, item)

    return {
        "mode": decision["mode"],
        "reason": decision["reason"],
        "container": item.container,
        "video_codec": item.video_codec,
        "audio_codec": item.audio_codec,
        "direct_url": f"/api/stream/{item.id}",
        "hls_url": f"/api/hls/{item.id}/a0/o0/index.m3u8",
        "hls_base": f"/api/hls/{item.id}",
        "audio_tracks": audio_tracks,
        "subtitle_tracks": subtitle_tracks,
        "subtitles_url": f"/api/subtitles/{item.id}",
        "intro": intro,
        "duration": total_duration,
        "next_episode": (
            {
                "id": nxt.id,
                "season": nxt.season,
                "episode": nxt.episode,
                "title": nxt.title or nxt.parsed_title,
            }
            if nxt else None
        ),
    }
