"""TMDB metadata client (synchronous — used from the background scanner)."""
from __future__ import annotations

from typing import Optional

import httpx

from .config import TMDB_API_KEY, TMDB_LANGUAGE

BASE = "https://api.themoviedb.org/3"


class TMDBClient:
    def __init__(self, api_key: str = TMDB_API_KEY):
        self.api_key = api_key
        self._client = httpx.Client(base_url=BASE, timeout=15.0)

    @property
    def enabled(self) -> bool:
        return bool(self.api_key)

    def _get(self, path: str, **params) -> Optional[dict]:
        if not self.enabled:
            return None
        params["api_key"] = self.api_key
        params.setdefault("language", TMDB_LANGUAGE)
        try:
            r = self._client.get(path, params=params)
            r.raise_for_status()
            return r.json()
        except httpx.HTTPError:
            return None

    # --- Movies -----------------------------------------------------------
    def search_movie(self, title: str, year: Optional[int] = None) -> Optional[dict]:
        params = {"query": title}
        if year:
            params["year"] = year
        data = self._get("/search/movie", **params)
        if not data or not data.get("results"):
            return None
        return data["results"][0]

    def movie_details(self, movie_id: int) -> Optional[dict]:
        return self._get(f"/movie/{movie_id}", append_to_response="credits")

    # --- TV ---------------------------------------------------------------
    def search_tv(self, title: str, year: Optional[int] = None) -> Optional[dict]:
        params = {"query": title}
        if year:
            params["first_air_date_year"] = year
        data = self._get("/search/tv", **params)
        if not data or not data.get("results"):
            return None
        return data["results"][0]

    def tv_details(self, tv_id: int) -> Optional[dict]:
        return self._get(f"/tv/{tv_id}", append_to_response="credits")

    def tv_episode(self, tv_id: int, season: int, episode: int) -> Optional[dict]:
        return self._get(f"/tv/{tv_id}/season/{season}/episode/{episode}")

    def close(self):
        self._client.close()


def cast_from_credits(credits: Optional[dict], limit: int = 12) -> list:
    if not credits:
        return []
    people = credits.get("cast", [])[:limit]
    return [
        {
            "name": p.get("name"),
            "character": p.get("character"),
            "profile_path": p.get("profile_path"),
        }
        for p in people
    ]


def genre_names(details: Optional[dict]) -> list:
    if not details:
        return []
    return [g["name"] for g in details.get("genres", []) if g.get("name")]
