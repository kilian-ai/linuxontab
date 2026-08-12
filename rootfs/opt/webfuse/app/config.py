"""Application configuration, loaded from environment / .env."""
import os
from pathlib import Path

from dotenv import load_dotenv

# Load .env from the backend directory if present.
BACKEND_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BACKEND_DIR / ".env")

# Where the SQLite DB and any cached artwork live.
DATA_DIR = Path(os.getenv("WEBFUSE_DATA_DIR", BACKEND_DIR / "data")).resolve()
DATA_DIR.mkdir(parents=True, exist_ok=True)

DATABASE_URL = f"sqlite:///{DATA_DIR / 'webfuse.db'}"

# TMDB — https://www.themoviedb.org/settings/api
TMDB_API_KEY = os.getenv("TMDB_API_KEY", "").strip()
TMDB_LANGUAGE = os.getenv("TMDB_LANGUAGE", "en-US")
TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p"

# Which extensions we treat as playable video.
# NOTE: ".ts" is deliberately excluded — it collides with TypeScript source files
# and causes massive false positives when scanning folders that contain code.
# ".m2ts" (Blu-ray) is unambiguous and kept.
VIDEO_EXTENSIONS = {
    ".mp4", ".m4v", ".mkv", ".webm", ".mov", ".avi",
    ".wmv", ".flv", ".mpg", ".mpeg", ".m2ts",
}

# Directories skipped during scanning (dev/junk trees that never hold real media).
IGNORE_DIRS = {
    "node_modules", ".git", ".svn", ".hg", "__pycache__", ".venv", "venv",
    "dist", "build", ".next", ".nuxt", ".cache", ".gradle", "target",
    "site-packages", ".Trash", ".Trashes", "Library", ".pnpm-store",
}

# Extensions the browser can usually direct-play without transcoding.
BROWSER_FRIENDLY_EXTENSIONS = {".mp4", ".m4v", ".webm", ".mov"}
# Same set without the dot, for comparing against MediaItem.container.
BROWSER_FRIENDLY_CONTAINERS = {e.lstrip(".") for e in BROWSER_FRIENDLY_EXTENSIONS}

# ffmpeg/ffprobe for probing + on-the-fly transcoding of non-friendly files.
FFMPEG_BIN = os.getenv("FFMPEG_BIN", "ffmpeg")
FFPROBE_BIN = os.getenv("FFPROBE_BIN", "ffprobe")

# Skip-intro: when an episode file has no chapter markers, offer a user-initiated
# skip to this many seconds in (a typical TV intro length).
DEFAULT_INTRO_END = int(os.getenv("WEBFUSE_INTRO_SECONDS", "90"))

# Codecs browsers can decode in a <video> element (direct play).
BROWSER_VIDEO_CODECS = {"h264", "avc1", "vp8", "vp9", "av1", "av01"}
BROWSER_AUDIO_CODECS = {"aac", "mp3", "opus", "vorbis", "flac"}

# BitTorrent integration (optional).
# Transmission RPC endpoint; leave default when Transmission runs on this host.
TRANSMISSION_URL = os.getenv(
    "TRANSMISSION_URL", "http://127.0.0.1:9091/transmission/rpc"
)
# Torrent search backend. Prefer Prowlarr's native aggregate API (searches all
# configured indexers at once); fall back to a single Torznab endpoint. Search
# is disabled until one of these is configured.
PROWLARR_URL = os.getenv("PROWLARR_URL", "").strip().rstrip("/")
PROWLARR_APIKEY = os.getenv("PROWLARR_APIKEY", "").strip()
TORZNAB_URL = os.getenv("TORZNAB_URL", "").strip()
TORZNAB_APIKEY = os.getenv("TORZNAB_APIKEY", "").strip()
# x264 speed/quality knobs for the live transcode.
TRANSCODE_PRESET = os.getenv("WEBFUSE_TRANSCODE_PRESET", "veryfast")
TRANSCODE_CRF = os.getenv("WEBFUSE_TRANSCODE_CRF", "23")
HLS_SEGMENT_SECONDS = 4
