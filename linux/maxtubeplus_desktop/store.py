"""Local state in XDG directories (~/.config/maxtubeplus, ~/.cache/maxtubeplus).

Everything is plain JSON written atomically. Nothing is synced or uploaded.
"""
import json
import os
import threading
import time

APP = "maxtubeplus"


def _xdg(var, fallback):
    return os.environ.get(var) or os.path.expanduser(fallback)


CONFIG_DIR = os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), APP)
CACHE_DIR = os.path.join(_xdg("XDG_CACHE_HOME", "~/.cache"), APP)
DATA_DIR = os.path.join(_xdg("XDG_DATA_HOME", "~/.local/share"), APP)


def default_download_dir():
    try:
        import subprocess
        videos = subprocess.run(["xdg-user-dir", "VIDEOS"], capture_output=True, text=True, timeout=2).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        videos = ""
    if not videos or videos == os.path.expanduser("~"):
        videos = os.path.expanduser("~/Videos")
    return os.path.join(videos, "MaxTubePlus")


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


DEFAULT_SETTINGS = {
    # Same meaning and defaults as the iOS keys in MTPCommon.m
    "dearrow.titles": True,
    "dearrow.thumbnails": True,
    "search.filters": True,
    "search.fetchLikes": True,
    "search.flexibleDates": False,
    "search.looseNames": False,
    "search.sortMode": 0,               # 0 relevance, 1 recency
    "downloads.maxHeight": 1080,        # 0 = best
    "downloads.audioOnly": False,
    "downloads.notifications": True,
    "downloads.maxConcurrent": 2,
    "downloads.maxRetries": 5,
    "downloads.directory": "",          # empty = ~/Videos/MaxTubePlus
    "player.command": "mpv",
}

DEFAULT_FILTERS = {
    "minLikes": -1, "minDuration": -1, "maxDuration": -1, "maxAge": -1,
    "after": -1, "before": -1, "include": [], "exclude": [],
}


class Store:
    """Thread-safe JSON documents: settings, filters, bans, subscriptions, comments."""

    def __init__(self, config_dir=None):
        self.dir = config_dir or CONFIG_DIR
        self._lock = threading.RLock()
        self._listeners = []
        self.settings = {**DEFAULT_SETTINGS, **_read_json(self._path("settings"), {})}
        self.filters = {**DEFAULT_FILTERS, **_read_json(self._path("filters"), {})}
        self.bans = _read_json(self._path("bans"), [])
        self.subscriptions = _read_json(self._path("subscriptions"), [])
        self.comments = _read_json(self._path("comments"), {"records": [], "lastImport": None})

    def _path(self, name):
        return os.path.join(self.dir, f"{name}.json")

    def listen(self, callback):
        self._listeners.append(callback)

    def unlisten(self, callback):
        if callback in self._listeners:
            self._listeners.remove(callback)

    def save(self, name):
        with self._lock:
            _write_json(self._path(name), getattr(self, name))
        for callback in list(self._listeners):
            callback(name)

    # settings
    def get(self, key):
        return self.settings.get(key, DEFAULT_SETTINGS.get(key))

    def set(self, key, value):
        with self._lock:
            self.settings[key] = value
        self.save("settings")

    def reset_settings(self):
        with self._lock:
            self.settings = dict(DEFAULT_SETTINGS)
        self.save("settings")

    def download_dir(self):
        return self.get("downloads.directory") or default_download_dir()

    # bans
    def ban(self, handle, channel_id=None, name=None):
        with self._lock:
            entry = next((b for b in self.bans if b["handle"] == handle), None)
            if not entry:
                entry = {"handle": handle, "added": int(time.time())}
                self.bans.insert(0, entry)
            if channel_id:
                entry["channelId"] = channel_id
            if name:
                entry["name"] = name
        self.save("bans")
        return entry

    def unban(self, handle):
        with self._lock:
            self.bans = [b for b in self.bans if b["handle"] != handle]
        self.save("bans")

    # subscriptions
    def subscribe(self, channel_id, name, handle=None):
        with self._lock:
            if any(s["channelId"] == channel_id for s in self.subscriptions):
                return
            self.subscriptions.append({"channelId": channel_id, "name": name, "handle": handle})
        self.save("subscriptions")

    def unsubscribe(self, channel_id):
        with self._lock:
            self.subscriptions = [s for s in self.subscriptions if s["channelId"] != channel_id]
        self.save("subscriptions")

    def is_subscribed(self, channel_id):
        return any(s["channelId"] == channel_id for s in self.subscriptions)


class JsonCache:
    """Small disk cache with per-entry TTL (DeArrow, likes, channel lookups)."""

    def __init__(self, name, ttl):
        self.path = os.path.join(CACHE_DIR, f"{name}.json")
        self.ttl = ttl
        self._lock = threading.Lock()
        self._data = _read_json(self.path, {})
        self._dirty = 0

    def get(self, key):
        with self._lock:
            entry = self._data.get(key)
        if entry and time.time() - entry.get("t", 0) < entry.get("ttl", self.ttl):
            return entry.get("v")
        return None

    def has(self, key):
        with self._lock:
            entry = self._data.get(key)
        return bool(entry) and time.time() - entry.get("t", 0) < entry.get("ttl", self.ttl)

    def put(self, key, value, ttl=None):
        with self._lock:
            self._data[key] = {"v": value, "t": time.time(), "ttl": ttl or self.ttl}
            if len(self._data) > 20000:
                for old in sorted(self._data, key=lambda k: self._data[k]["t"])[:5000]:
                    del self._data[old]
            self._dirty += 1
            flush = self._dirty >= 25
        if flush:
            self.flush()

    def flush(self):
        with self._lock:
            data = dict(self._data)
            self._dirty = 0
        _write_json(self.path, data)
