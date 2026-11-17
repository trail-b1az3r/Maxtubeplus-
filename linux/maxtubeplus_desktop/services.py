"""Third-party APIs, same ones and same rules as the iOS tweak.

* DeArrow (sponsor.ajay.app) - community titles/thumbnails. A submission is
  used when it is locked or has non-negative votes; an "original" submission
  or no submission keeps YouTube's own. Data: CC BY-NC-SA 4.0.
* Return YouTube Dislike (returnyoutubedislikeapi.com) - like counts, because
  search results don't carry them.
"""
import json
import re
import urllib.parse
import urllib.request

from .store import JsonCache

USER_AGENT = "MaxTubePlus-Desktop/1.0 (Linux)"
_dearrow_cache = JsonCache("dearrow", ttl=6 * 3600)
_likes_cache = JsonCache("likes", ttl=24 * 3600)


def _get_json(url, timeout=10):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def clean_dearrow_title(title):
    """DeArrow marks words that keep original casing with a leading '>'."""
    title = re.sub(r"(^|\s)>(?=\S)", r"\1", title)
    return re.sub(r"\s+", " ", title).strip()


def parse_branding(data):
    """Returns {"title": str|None, "time": float|None} from a branding response."""
    result = {"title": None, "time": None}
    for entry in data.get("titles") or []:
        if not (entry.get("locked") or (entry.get("votes") or 0) >= 0):
            continue
        if entry.get("original"):
            break
        if entry.get("title"):
            result["title"] = clean_dearrow_title(entry["title"])
            break
    for entry in data.get("thumbnails") or []:
        if not (entry.get("locked") or (entry.get("votes") or 0) >= 0):
            continue
        if entry.get("original"):
            break
        if isinstance(entry.get("timestamp"), (int, float)):
            result["time"] = entry["timestamp"]
            break
    return result


def dearrow_branding(video_id):
    """Cached; network on miss. Never raises (returns no replacement on errors)."""
    cached = _dearrow_cache.get(video_id)
    if cached is not None:
        return cached
    try:
        branding = parse_branding(_get_json("https://sponsor.ajay.app/api/branding?videoID=" + urllib.parse.quote(video_id)))
        ttl = None if (branding["title"] or branding["time"] is not None) else 2 * 3600
    except urllib.error.HTTPError as error:
        if error.code != 404:  # 404 == no submissions
            return {"title": None, "time": None}
        branding, ttl = {"title": None, "time": None}, 2 * 3600
    except (urllib.error.URLError, OSError, ValueError):
        return {"title": None, "time": None}
    _dearrow_cache.put(video_id, branding, ttl)
    return branding


def dearrow_thumbnail_url(video_id, time_seconds):
    return f"https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID={urllib.parse.quote(video_id)}&time={time_seconds}"


def cached_likes(video_id):
    value = _likes_cache.get(video_id)
    return -1 if value is None else value


def fetch_likes(video_id):
    value = _likes_cache.get(video_id)
    if value is not None:
        return value
    try:
        data = _get_json("https://returnyoutubedislikeapi.com/votes?videoId=" + urllib.parse.quote(video_id), timeout=8)
        likes = int(data.get("likes", -1))
    except (urllib.error.URLError, OSError, ValueError, TypeError):
        return -1
    _likes_cache.put(video_id, likes)
    return likes


def flush_caches():
    _dearrow_cache.flush()
    _likes_cache.flush()
