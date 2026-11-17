"""Background download queue (desktop counterpart of MTPDownloadManager).

yt-dlp does the transfers. The queue is persisted, so downloads survive app
restarts: unfinished items resume from their .part files (yt-dlp continues
partial downloads). Pause = stop the transfer and keep the partial file;
retry uses the same exponential back-off as iOS (core.retry_delay).
"""
import json
import os
import threading
import time
import uuid

from . import core
from .store import DATA_DIR, _write_json

QUEUED, DOWNLOADING, PAUSED, PROCESSING, COMPLETED, FAILED, CANCELLED = (
    "queued", "downloading", "paused", "processing", "completed", "failed", "cancelled")


class _Stop(Exception):
    pass


class DownloadManager:
    def __init__(self, store, on_change=None, on_notify=None):
        self.store = store
        self.on_change = on_change or (lambda item: None)
        self.on_notify = on_notify or (lambda title, body: None)
        self.path = os.path.join(DATA_DIR, "downloads.json")
        self._lock = threading.RLock()
        self._stop = {}
        self._threads = {}
        try:
            with open(self.path, encoding="utf-8") as handle:
                self.items = json.load(handle)
        except (OSError, ValueError):
            self.items = []
        # Interrupted-download recovery: anything that was running is requeued.
        recovered = 0
        for item in self.items:
            if item["state"] in (DOWNLOADING, PROCESSING):
                item["state"] = QUEUED
                recovered += 1
        self.recovered = recovered
        self._persist()

    # --- persistence -----------------------------------------------------
    def _persist(self):
        with self._lock:
            _write_json(self.path, self.items)

    def _changed(self, item, persist=True):
        if persist:
            self._persist()
        self.on_change(item)

    # --- public API ------------------------------------------------------
    def enqueue(self, video_id, title, channel=""):
        audio_only = bool(self.store.get("downloads.audioOnly"))
        item = {"id": uuid.uuid4().hex, "video": video_id, "title": title or video_id, "channel": channel,
                "audioOnly": audio_only, "maxHeight": int(self.store.get("downloads.maxHeight") or 0),
                "state": QUEUED, "progress": 0.0, "attempts": 0, "error": None, "output": None,
                "created": int(time.time()), "retryAt": None, "speed": None}
        with self._lock:
            self.items.insert(0, item)
        self._changed(item)
        self.pump()
        return item

    def pause(self, item):
        if item["state"] in (DOWNLOADING, QUEUED):
            item["state"] = PAUSED
            self._signal_stop(item)
            self._changed(item)
            self.pump()

    def resume(self, item):
        if item["state"] == PAUSED:
            item["state"], item["retryAt"] = QUEUED, None
            self._changed(item)
            self.pump()

    def cancel(self, item):
        if item["state"] in (QUEUED, DOWNLOADING, PAUSED, FAILED):
            item["state"] = CANCELLED
            self._signal_stop(item)
            self._cleanup_partials(item)
            self._changed(item)
            self.pump()

    def retry(self, item):
        if item["state"] in (FAILED, CANCELLED):
            item.update(state=QUEUED, attempts=0, error=None, retryAt=None)
            self._changed(item)
            self.pump()

    def remove(self, item, delete_file=False):
        self._signal_stop(item)
        if delete_file and item.get("output") and os.path.exists(item["output"]):
            os.remove(item["output"])
        self._cleanup_partials(item)
        with self._lock:
            self.items = [i for i in self.items if i["id"] != item["id"]]
        self._changed(item)

    def clear_finished(self):
        with self._lock:
            self.items = [i for i in self.items if i["state"] not in (COMPLETED, CANCELLED, FAILED)]
        self._changed(None)

    def storage_used(self):
        total = 0
        folder = self.store.download_dir()
        for root, _, files in os.walk(folder):
            for name in files:
                try:
                    total += os.path.getsize(os.path.join(root, name))
                except OSError:
                    pass
        return total

    def shutdown(self):
        for item in list(self.items):
            if item["state"] == DOWNLOADING:
                self._signal_stop(item)
                item["state"] = QUEUED  # resumes next launch
        self._persist()

    # --- scheduling ------------------------------------------------------
    def pump(self):
        limit = max(1, int(self.store.get("downloads.maxConcurrent") or 1))
        with self._lock:
            running = sum(1 for i in self.items if i["state"] == DOWNLOADING)
            now = time.time()
            for item in reversed(self.items):  # oldest first
                if running >= limit:
                    break
                if item["state"] != QUEUED or (item.get("retryAt") and item["retryAt"] > now):
                    continue
                item["state"], item["error"], item["retryAt"] = DOWNLOADING, None, None
                running += 1
                stop = threading.Event()
                self._stop[item["id"]] = stop
                thread = threading.Thread(target=self._run, args=(item, stop), daemon=True, name=f"download-{item['video']}")
                self._threads[item["id"]] = thread
                thread.start()
                self.on_change(item)
        self._persist()

    def _signal_stop(self, item):
        stop = self._stop.get(item["id"])
        if stop:
            stop.set()

    def _format(self, item):
        if item["audioOnly"]:
            return "bestaudio[ext=m4a]/bestaudio"
        height = item.get("maxHeight") or 0
        cap = f"[height<={height}]" if height else ""
        return f"bestvideo{cap}+bestaudio/best{cap}/best"

    def _cleanup_partials(self, item):
        folder = self.store.download_dir()
        try:
            for name in os.listdir(folder):
                if f"[{item['video']}]" in name and (name.endswith(".part") or ".part-" in name or name.endswith(".ytdl")):
                    os.remove(os.path.join(folder, name))
        except OSError:
            pass

    def _run(self, item, stop):
        try:
            import yt_dlp
        except ImportError:
            self._fail(item, "yt-dlp is not installed (pacman -S yt-dlp)")
            return
        folder = self.store.download_dir()
        os.makedirs(folder, exist_ok=True)

        def hook(status):
            if stop.is_set():
                raise _Stop()
            if status.get("status") == "downloading":
                total = status.get("total_bytes") or status.get("total_bytes_estimate") or 0
                if total:
                    item["progress"] = min(0.999, status.get("downloaded_bytes", 0) / total)
                item["speed"] = status.get("speed")
                self.on_change(item)
            elif status.get("status") == "finished":
                item["state"] = PROCESSING
                self.on_change(item)

        options = {
            "format": self._format(item),
            "outtmpl": os.path.join(folder, "%(title).120B [%(id)s].%(ext)s"),
            "continuedl": True,
            "noprogress": True,
            "quiet": True,
            "no_warnings": True,
            "progress_hooks": [hook],
            "merge_output_format": "mp4",
        }
        if item["audioOnly"]:
            options["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}]
        try:
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(f"https://www.youtube.com/watch?v={item['video']}", download=True)
                output = None
                for requested in (info or {}).get("requested_downloads") or []:
                    output = requested.get("filepath") or output
                item["output"] = output or ydl.prepare_filename(info)
                if not item.get("title") or item["title"] == item["video"]:
                    item["title"] = (info or {}).get("title") or item["title"]
            item.update(state=COMPLETED, progress=1.0, error=None, speed=None)
            self._changed(item)
            if self.store.get("downloads.notifications"):
                self.on_notify("Download complete", item["title"])
        except _Stop:
            # Paused or cancelled: state was already set by pause()/cancel().
            item["speed"] = None
            self._changed(item)
        except Exception as error:  # yt-dlp raises DownloadError and friends
            if stop.is_set():
                self._changed(item)
            else:
                self._fail(item, explain_error(str(error)))
        finally:
            self._stop.pop(item["id"], None)
            self._threads.pop(item["id"], None)
            self.pump()

    def _fail(self, item, message):
        item["attempts"] += 1
        max_retries = int(self.store.get("downloads.maxRetries") or 0)
        if item["attempts"] <= max_retries:
            delay = core.retry_delay(item["attempts"] - 1)
            item.update(state=QUEUED, error=message, retryAt=time.time() + delay)
            threading.Timer(delay, self.pump).start()
        else:
            item.update(state=FAILED, error=message)
            if self.store.get("downloads.notifications"):
                self.on_notify("Download failed", f"{item['title']} — {message}")
        self._changed(item)


def explain_error(message):
    """Turns common yt-dlp failures into something actionable."""
    message = message.replace("ERROR: ", "").strip()
    if "403" in message:
        return ("YouTube refused the video stream (HTTP 403). Update yt-dlp (sudo pacman -Syu yt-dlp) and make sure "
                "deno is installed; VPN or datacenter connections are often blocked.")
    if "JavaScript runtime" in message or "Requested format is not available" in message:
        return "yt-dlp needs a JavaScript runtime for YouTube: install deno (sudo pacman -S deno)."
    if "ffmpeg" in message.lower():
        return "ffmpeg is needed to merge audio and video: sudo pacman -S ffmpeg"
    return message[:300]


def describe(item):
    state = item["state"]
    if state == QUEUED:
        return "Waiting to retry" if item.get("retryAt") else "Queued"
    if state == DOWNLOADING:
        return f"Downloading {item.get('progress', 0) * 100:.0f}%"
    if state == PAUSED:
        return f"Paused at {item.get('progress', 0) * 100:.0f}%"
    if state == PROCESSING:
        return "Merging audio and video…"
    if state == COMPLETED:
        return "Completed"
    if state == FAILED:
        return "Failed: " + (item.get("error") or "unknown error")
    return "Cancelled"
