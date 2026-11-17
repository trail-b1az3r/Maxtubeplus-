"""Pages: Search, Subscriptions, Downloads, Commented videos, Banned creators."""
import os
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from .. import downloads as dl  # noqa: E402
from .. import filtering, services, takeout, youtube  # noqa: E402
from .widgets import (VideoRow, boxed_list, format_count, run_async, scrolled_clamp,  # noqa: E402
                      status_page)


class Page(Adw.NavigationPage):
    """A content page: header bar + body (+ optional bottom bar)."""

    def __init__(self, window, title, tag):
        super().__init__(title=title, tag=tag)
        self.window = window
        self.store = window.store
        self.header = Adw.HeaderBar()
        self.toolbar = Adw.ToolbarView()
        self.toolbar.add_top_bar(self.header)
        self.set_child(self.toolbar)

    def set_body(self, widget):
        self.toolbar.set_content(widget)


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

class SearchPage(Page):
    def __init__(self, window):
        super().__init__(window, "Search", "search")
        self.query = ""
        self.continuation = None
        self.rows = []
        self.hidden = 0
        self.entry = Gtk.SearchEntry(placeholder_text="Search YouTube", hexpand=True)
        self.entry.set_size_request(320, -1)
        self.entry.connect("activate", lambda e: self.run(e.get_text()))
        self.header.set_title_widget(Adw.Clamp(maximum_size=520, child=self.entry))
        self.filter_button = Gtk.Button(label="Filters", tooltip_text="Search filters")
        self.filter_button.connect("clicked", lambda *_: self.window.show_filters())
        self.header.pack_end(self.filter_button)

        self.banner = Adw.Banner(button_label="Edit filters")
        self.banner.connect("button-clicked", lambda *_: self.window.show_filters())
        self.toolbar.add_top_bar(self.banner)

        self.list = boxed_list()
        self.more = Gtk.Button(label="Load more", halign=Gtk.Align.CENTER, margin_top=12, visible=False)
        self.more.add_css_class("pill")
        self.more.connect("clicked", lambda *_: self.load_more())
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.append(self.list)
        box.append(self.more)
        self.results = scrolled_clamp(box)
        self.spinner = Adw.Spinner() if hasattr(Adw, "Spinner") else Gtk.Spinner(spinning=True)
        self.stack = Gtk.Stack()
        self.stack.add_named(status_page("system-search-symbolic", "Search YouTube",
                                         "Filters, topics and banned creators from MaxTubePlus apply to every search."), "empty")
        self.stack.add_named(self._centered(self.spinner), "loading")
        self.stack.add_named(self.results, "results")
        self.error_page = status_page("network-error-symbolic", "Couldn't search")
        self.stack.add_named(self.error_page, "error")
        self.none_page = status_page("edit-find-symbolic", "No results", "Try fewer filters, or turn on Flexible dates / Loose names.")
        self.stack.add_named(self.none_page, "none")
        self.set_body(self.stack)
        self.store.listen(self._store_changed)
        self.update_banner()

    def _centered(self, widget):
        box = Gtk.Box(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        widget.set_size_request(32, 32)
        box.append(widget)
        return box

    def _store_changed(self, name):
        if name in ("filters", "bans", "settings"):
            GLib.idle_add(lambda: (self.update_banner(), self.reapply(), False)[2])

    def update_banner(self):
        count = len(filtering.active_filter_descriptions(self.store))
        bans = len(self.store.bans)
        parts = []
        if self.store.get("search.filters") and count:
            parts.append(f"{count} filter{'s' if count != 1 else ''} active")
        if bans:
            parts.append(f"{bans} banned creator{'s' if bans != 1 else ''}")
        if self.hidden:
            parts.append(f"{self.hidden} result{'s' if self.hidden != 1 else ''} hidden")
        self.banner.set_title(" · ".join(parts))
        self.banner.set_revealed(bool(parts))
        self.filter_button.set_label(f"Filters ({count})" if count and self.store.get("search.filters") else "Filters")

    def run(self, query):
        query = query.strip()
        if not query:
            return
        self.query = query
        self.entry.set_text(query)
        self.continuation = None
        for row in self.rows:
            self.list.remove(row)
        self.rows, self.hidden = [], 0
        self.stack.set_visible_child_name("loading")
        params = filtering.server_params(self.store)
        run_async(lambda: youtube.search(query, params), self._got, self._failed)

    def load_more(self):
        if not self.continuation:
            return
        self.more.set_sensitive(False)
        token = self.continuation
        run_async(lambda: youtube.search(self.query, continuation=token), self._got, self._failed)

    def _failed(self, error):
        self.more.set_sensitive(True)
        if self.rows:
            self.window.toast(str(error))
            return
        self.error_page.set_description(str(error))
        self.stack.set_visible_child_name("error")

    def _got(self, result):
        items, token = result
        self.continuation = token
        self.more.set_visible(bool(token))
        self.more.set_sensitive(True)
        for item in filtering.sort_items(items, self.store):
            row = VideoRow(self.window, item)
            self.rows.append(row)
            self.list.append(row)
        self.reapply()
        self.stack.set_visible_child_name("results" if any(r.get_visible() for r in self.rows) or token else "none")

    def reapply(self):
        """Re-evaluates every row (filters/bans changed or likes arrived)."""
        hidden, need_likes = 0, []
        for row in self.rows:
            verdict, _reason = filtering.evaluate(row.item, self.store)
            if verdict == "unknown" and self.store.get("search.fetchLikes"):
                need_likes.append(row)
            row.set_visible(verdict != "hide")
            hidden += verdict == "hide"
        self.hidden = hidden
        self.update_banner()
        for row in need_likes:
            row.item.likes = -2  # fetching; avoid re-queueing
            item = row.item

            def work(video_id=item.id):
                return services.fetch_likes(video_id)

            def done(likes, row=row):
                row.item.likes = likes if likes >= 0 else -1
                row.refresh_subtitle()
                verdict, _ = filtering.evaluate(row.item, self.store)
                if verdict == "hide" and row.get_visible():
                    row.set_visible(False)
                    self.hidden += 1
                    self.update_banner()

            run_async(work, done)


# ---------------------------------------------------------------------------
# Subscriptions (local, no account)
# ---------------------------------------------------------------------------

class SubscriptionsPage(Page):
    def __init__(self, window):
        super().__init__(window, "Subscriptions", "subscriptions")
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh")
        refresh.connect("clicked", lambda *_: self.refresh())
        self.header.pack_end(refresh)
        manage = Gtk.Button(label="Channels", tooltip_text="Add or remove channels")
        manage.connect("clicked", lambda *_: self.window.show_channels())
        self.header.pack_start(manage)
        self.list = boxed_list()
        self.stack = Gtk.Stack()
        self.stack.add_named(status_page("view-list-bullet-symbolic", "No subscriptions",
                                         "Subscribe from any search result's menu, or add a channel by @handle under Channels. "
                                         "Subscriptions are stored on this computer only."), "empty")
        self.stack.add_named(scrolled_clamp(self.list), "feed")
        self.loading = status_page("content-loading-symbolic", "Loading uploads…")
        self.stack.add_named(self.loading, "loading")
        self.set_body(self.stack)
        self.rows = []
        self.store.listen(lambda name: name in ("subscriptions", "bans") and GLib.idle_add(lambda: (self.refresh(), False)[1]))
        self.loaded = False

    def refresh(self):
        subs = list(self.store.subscriptions)
        if not subs:
            self.stack.set_visible_child_name("empty")
            return
        self.stack.set_visible_child_name("loading")

        def work():
            items, errors = [], 0
            for sub in subs:
                try:
                    items.extend(youtube.channel_feed(sub["channelId"]))
                except youtube.YouTubeError:
                    errors += 1
            items.sort(key=lambda i: -i.published_unix)
            return items[:150], errors

        run_async(work, self._got)

    def _got(self, result):
        items, errors = result
        for row in self.rows:
            self.list.remove(row)
        self.rows = []
        for item in items:
            if filtering.is_banned(item, self.store):
                continue
            row = VideoRow(self.window, item)
            self.rows.append(row)
            self.list.append(row)
        self.loaded = True
        self.stack.set_visible_child_name("feed" if self.rows else "empty")
        if errors:
            self.window.toast(f"{errors} channel feed{'s' if errors != 1 else ''} couldn't be loaded")


# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

class DownloadRow(Adw.ActionRow):
    def __init__(self, page, item):
        super().__init__(title_lines=2)
        self.page, self.item = page, item
        self.progress = Gtk.ProgressBar(valign=Gtk.Align.CENTER, width_request=90)
        self.add_suffix(self.progress)
        self.buttons = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        self.add_suffix(self.buttons)
        self.update()

    def _button(self, icon, tooltip, callback, destructive=False):
        button = Gtk.Button(icon_name=icon, tooltip_text=tooltip, valign=Gtk.Align.CENTER)
        button.add_css_class("flat")
        if destructive:
            button.add_css_class("error")
        button.connect("clicked", lambda *_: callback())
        self.buttons.append(button)

    def update(self):
        item, manager = self.item, self.page.window.downloads
        self.set_title(GLib.markup_escape_text(item["title"]))
        quality = "Audio" if item["audioOnly"] else (f"≤{item['maxHeight']}p" if item.get("maxHeight") else "Best")
        self.set_subtitle(GLib.markup_escape_text(f"{quality} · {dl.describe(item)}"))
        self.progress.set_visible(item["state"] in (dl.DOWNLOADING, dl.PAUSED, dl.PROCESSING))
        self.progress.set_fraction(item.get("progress") or 0)
        while (child := self.buttons.get_first_child()) is not None:
            self.buttons.remove(child)
        state = item["state"]
        if state in (dl.DOWNLOADING, dl.QUEUED):
            self._button("media-playback-pause-symbolic", "Pause", lambda: manager.pause(item))
            self._button("process-stop-symbolic", "Cancel", lambda: manager.cancel(item))
        elif state == dl.PAUSED:
            self._button("media-playback-start-symbolic", "Resume", lambda: manager.resume(item))
            self._button("process-stop-symbolic", "Cancel", lambda: manager.cancel(item))
        elif state in (dl.FAILED, dl.CANCELLED):
            self._button("view-refresh-symbolic", "Retry", lambda: manager.retry(item))
        elif state == dl.COMPLETED and item.get("output"):
            self._button("media-playback-start-symbolic", "Play", lambda: self.page.window.play_file(item["output"]))
            self._button("folder-open-symbolic", "Show in folder", lambda: self.page.window.show_in_folder(item["output"]))
        self._button("user-trash-symbolic", "Delete", lambda: self.page.confirm_delete(item), destructive=True)


class DownloadsPage(Page):
    def __init__(self, window):
        super().__init__(window, "Downloads", "downloads")
        clear = Gtk.Button(label="Clear finished", tooltip_text="Remove finished downloads from the list (files are kept)")
        clear.connect("clicked", lambda *_: window.downloads.clear_finished())
        self.header.pack_end(clear)
        folder = Gtk.Button(icon_name="folder-open-symbolic", tooltip_text="Show downloads folder")
        folder.connect("clicked", lambda *_: window.open_uri("file://" + window.store.download_dir()))
        self.header.pack_start(folder)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        storage_group = Adw.PreferencesGroup(title="Storage", description=f"Files are saved to {window.store.download_dir()}.")
        self.storage = Adw.ActionRow(title="", subtitle="")
        storage_group.add(self.storage)
        box.append(storage_group)
        self.queue_group = Adw.PreferencesGroup(
            title="Queue",
            description="Downloads keep running while the window is closed to the background, and unfinished downloads resume when MaxTubePlus starts again.")
        box.append(self.queue_group)
        self.empty = Adw.ActionRow(title="No downloads", subtitle="Use “Download” in any video's menu.")
        self.queue_group.add(self.empty)
        self.set_body(scrolled_clamp(box))
        self.rows = {}
        self.reload()

    def reload(self):
        manager = self.window.downloads
        ids = {item["id"] for item in manager.items}
        for item_id in list(self.rows):
            if item_id not in ids:
                self.queue_group.remove(self.rows.pop(item_id))
        for item in manager.items:
            row = self.rows.get(item["id"])
            if row is None:
                row = DownloadRow(self, item)
                self.rows[item["id"]] = row
                self.queue_group.add(row)
            else:
                row.item = item
                row.update()
        self.empty.set_visible(not manager.items)
        self.update_storage()

    def update_storage(self):
        used = self.window.downloads.storage_used()
        try:
            stat = os.statvfs(os.path.expanduser("~"))
            free = stat.f_bavail * stat.f_frsize
        except OSError:
            free = 0
        self.storage.set_title(f"{GLib.format_size(used)} used")
        self.storage.set_subtitle(f"{GLib.format_size(free)} free on this disk")

    def confirm_delete(self, item):
        dialog = Adw.AlertDialog(heading="Delete download?", body=f"“{item['title']}” will be removed from the list"
                                 + (" and its file deleted." if item.get("output") else "."))
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("delete", "Delete")
        dialog.set_response_appearance("delete", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", lambda _d, r: r == "delete" and self.window.downloads.remove(item, delete_file=True))
        dialog.present(self.window)


# ---------------------------------------------------------------------------
# Commented videos
# ---------------------------------------------------------------------------

class CommentsPage(Page):
    def __init__(self, window):
        super().__init__(window, "Commented videos", "comments")
        self.entry = Gtk.SearchEntry(placeholder_text="Search your comments", hexpand=True)
        self.entry.connect("search-changed", lambda *_: self.reload())
        self.header.set_title_widget(Adw.Clamp(maximum_size=420, child=self.entry))
        self.sort = Gtk.DropDown.new_from_strings(["Recent", "Relevance"])
        self.sort.connect("notify::selected", lambda *_: self.reload())
        self.header.pack_end(self.sort)
        menu = Gio.Menu()
        menu.append("Import Google Takeout comments…", "win.import-takeout")
        menu.append("Open YouTube comment history (My Activity)", "win.my-activity")
        menu.append("How to export comments", "win.takeout-help")
        menu.append("Remove imported comments", "win.clear-comments")
        self.header.pack_start(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu, tooltip_text="Comment history"))
        self.list = boxed_list()
        self.stack = Gtk.Stack()
        self.stack.add_named(status_page("chat-bubbles-symbolic" if Gtk.IconTheme.get_for_display(window.get_display()).has_icon("chat-bubbles-symbolic") else "mail-unread-symbolic",
                                         "No comments imported yet",
                                         "Import comments.csv from Google Takeout. Takeout includes every comment, even on videos that aren't in your watch history."), "empty")
        self.stack.add_named(scrolled_clamp(self.list), "list")
        self.set_body(self.stack)
        self.titles = {}
        self.reload()

    def reload(self):
        records = takeout.search(self.store, self.entry.get_text(), sort_recent=self.sort.get_selected() == 0, titles=self.titles)
        while (row := self.list.get_first_child()) is not None:
            self.list.remove(row)
        if not self.store.comments["records"]:
            self.stack.set_visible_child_name("empty")
            return
        self.stack.set_visible_child_name("list")
        for record in records[:300]:
            date = time.strftime("%Y-%m-%d", time.localtime(record["d"])) if record.get("d") else ""
            title = self.titles.get(record["v"], "").split("\n")[0] or record["v"]
            row = Adw.ActionRow(title=GLib.markup_escape_text(title), subtitle=GLib.markup_escape_text(f"{date} · “{record['t']}”"),
                                activatable=True, subtitle_lines=3)
            row.connect("activated", lambda _r, r=record: self.window.play_url(
                f"https://www.youtube.com/watch?v={r['v']}" + (f"&lc={r['c']}" if r.get("c") else "")))
            self.list.append(row)
            if record["v"] not in self.titles:
                self._lookup(record["v"], row)

    def _lookup(self, video_id, row):
        import json
        import urllib.request

        def work():
            url = f"https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v={video_id}&format=json"
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.load(response)
            return f"{data.get('title', '')}\n{data.get('author_name', '')}"

        def done(text):
            self.titles[video_id] = text
            title, _, channel = text.partition("\n")
            row.set_title(GLib.markup_escape_text(title))
            row.set_subtitle(GLib.markup_escape_text(f"{channel} · {row.get_subtitle()}"))

        run_async(work, done, lambda _e: self.titles.setdefault(video_id, "Unavailable video"))


# ---------------------------------------------------------------------------
# Banned creators
# ---------------------------------------------------------------------------

class BansPage(Page):
    def __init__(self, window):
        super().__init__(window, "Banned creators", "bans")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        add_group = Adw.PreferencesGroup(
            title="Ban a creator",
            description="Everything from a banned creator — videos, Shorts and channel results — is hidden in Search and Subscriptions, "
                        "and the next item takes its place.")
        self.entry = Adw.EntryRow(title="@handle", show_apply_button=True)
        self.entry.connect("apply", lambda *_: self.ban())
        add_group.add(self.entry)
        box.append(add_group)
        self.group = Adw.PreferencesGroup(title="Banned", description="Select a creator to unban.")
        box.append(self.group)
        self.empty = Adw.ActionRow(title="No banned creators")
        self.group.add(self.empty)
        self.rows = []
        self.set_body(scrolled_clamp(box))
        self.store.listen(lambda name: name == "bans" and GLib.idle_add(lambda: (self.reload(), False)[1]))
        self.reload()

    def ban(self):
        self.window.ban_handle(self.entry.get_text())
        self.entry.set_text("")

    def reload(self):
        for row in self.rows:
            self.group.remove(row)
        self.rows = []
        for ban in self.store.bans:
            name = f"{ban['name']} (@{ban['handle']})" if ban.get("name") else f"@{ban['handle']}"
            row = Adw.ActionRow(title=GLib.markup_escape_text(name), subtitle=ban.get("channelId") or "Matched by handle", activatable=True)
            row.add_prefix(Gtk.Image(icon_name="action-unavailable-symbolic"))
            row.connect("activated", lambda _r, b=ban: self.confirm_unban(b))
            self.rows.append(row)
            self.group.add(row)
        self.empty.set_visible(not self.rows)

    def confirm_unban(self, ban):
        name = ban.get("name") or "@" + ban["handle"]
        dialog = Adw.AlertDialog(heading=f"Unban {name}", body="Their videos, Shorts and posts will appear again.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("unban", "Unban")
        dialog.set_response_appearance("unban", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", lambda _d, r: r == "unban" and self.store.unban(ban["handle"]))
        dialog.present(self.window)


__all__ = ["SearchPage", "SubscriptionsPage", "DownloadsPage", "CommentsPage", "BansPage", "format_count"]
