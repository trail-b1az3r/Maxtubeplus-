"""Shared widgets: background work, thumbnails, the video row."""
import threading
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

from .. import services  # noqa: E402

_pool = ThreadPoolExecutor(max_workers=6, thread_name_prefix="mtp")


def run_async(work, done=None, error=None):
    """Runs work() off the main thread; done(result) / error(exc) on the main loop."""
    def task():
        try:
            result = work()
        except Exception as exc:  # reported to the UI
            if error:
                GLib.idle_add(lambda: (error(exc), False)[1])
            return
        if done:
            GLib.idle_add(lambda: (done(result), False)[1])
    _pool.submit(task)


class ThumbnailCache:
    _lock = threading.Lock()
    _data = OrderedDict()

    @classmethod
    def load(cls, url, callback):
        if not url:
            return
        with cls._lock:
            texture = cls._data.get(url)
        if texture is not None:
            callback(texture)
            return

        def work():
            request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.read()

        def done(data):
            try:
                texture = Gdk.Texture.new_from_bytes(GLib.Bytes.new(data))
            except GLib.Error:
                return  # unsupported format (e.g. WebP without webp-pixbuf-loader): keep current image
            with cls._lock:
                cls._data[url] = texture
                while len(cls._data) > 400:
                    cls._data.popitem(last=False)
            callback(texture)

        run_async(work, done)


def youtube_thumbnail(video_id):
    return f"https://i.ytimg.com/vi/{video_id}/mqdefault.jpg"


def format_duration(seconds):
    if seconds is None or seconds < 0:
        return ""
    h, m, s = seconds // 3600, (seconds // 60) % 60, seconds % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def format_count(n, unit):
    if n is None or n < 0:
        return ""
    for div, suffix in ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")):
        if n >= div:
            return f"{n / div:.1f}".rstrip("0").rstrip(".") + f"{suffix} {unit}"
    return f"{n} {unit}"


class VideoRow(Adw.ActionRow):
    """A search/feed result: thumbnail, title, "channel · length · views · age"."""

    def __init__(self, window, item):
        super().__init__(activatable=True, title_lines=2, subtitle_lines=1)
        self.window = window
        self.item = item
        self.original_title = item.title
        self.set_title(GLib.markup_escape_text(item.title or item.id))
        self.picture = Gtk.Picture(content_fit=Gtk.ContentFit.COVER, can_shrink=True)
        self.picture.set_size_request(160 if item.kind != "channel" else 64, 90 if item.kind != "channel" else 64)
        frame = Gtk.Frame(child=self.picture, valign=Gtk.Align.CENTER, margin_top=6, margin_bottom=6)
        if item.kind == "channel":
            frame.add_css_class("circular")
        self.add_prefix(frame)
        self.refresh_subtitle()
        menu = Gtk.MenuButton(icon_name="view-more-symbolic", valign=Gtk.Align.CENTER, tooltip_text="More")
        menu.add_css_class("flat")
        menu.set_menu_model(window.item_menu(item))
        menu.connect("notify::active", lambda button, _p: button.get_active() and window.set_menu_item(item))
        self.add_suffix(menu)
        self.connect("activated", lambda _row: window.open_item(item))
        thumb = item.thumbnail if item.kind == "channel" else (youtube_thumbnail(item.id) if item.kind in ("video", "short") else item.thumbnail)
        ThumbnailCache.load(thumb, self.picture.set_paintable)
        if item.kind in ("video", "short"):
            self.apply_dearrow()

    def refresh_subtitle(self):
        item = self.item
        if item.kind == "channel":
            parts = ["@" + item.handle if item.handle else "", "Channel"]
        else:
            parts = [item.channel, "Short" if item.kind == "short" else format_duration(item.duration),
                     format_count(item.views, "views"), format_count(item.likes, "likes") if item.likes >= 0 else "",
                     item.published]
        self.set_subtitle(GLib.markup_escape_text(" · ".join(p for p in parts if p)))

    def apply_dearrow(self):
        store = self.window.store
        if not (store.get("dearrow.titles") or store.get("dearrow.thumbnails")):
            return
        video_id = self.item.id

        def done(branding):
            if store.get("dearrow.titles") and branding.get("title") and branding["title"] != self.original_title:
                self.set_title(GLib.markup_escape_text(branding["title"]))
                self.set_tooltip_text(f"Original title: {self.original_title}\n(DeArrow community title)")
            if store.get("dearrow.thumbnails") and branding.get("time") is not None:
                ThumbnailCache.load(services.dearrow_thumbnail_url(video_id, branding["time"]), self.picture.set_paintable)

        run_async(lambda: services.dearrow_branding(video_id), done)


def status_page(icon, title, description=""):
    page = Adw.StatusPage(icon_name=icon, title=title, description=description, vexpand=True)
    page.add_css_class("compact")
    return page


def boxed_list():
    box = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
    box.add_css_class("boxed-list")
    return box


def scrolled_clamp(child, maximum=900):
    clamp = Adw.Clamp(maximum_size=maximum, child=child, margin_top=12, margin_bottom=24, margin_start=12, margin_end=12)
    return Gtk.ScrolledWindow(child=clamp, vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
