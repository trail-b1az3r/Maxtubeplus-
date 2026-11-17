"""Application shell: window, sidebar navigation, shared actions."""
import os
import shutil
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

from .. import __version__, filtering, services, takeout, youtube  # noqa: E402
from ..downloads import DownloadManager  # noqa: E402
from ..store import Store  # noqa: E402
from .dialogs import ChannelsDialog, FiltersDialog, PreferencesDialog  # noqa: E402
from .pages import BansPage, CommentsPage, DownloadsPage, SearchPage, SubscriptionsPage  # noqa: E402
from .widgets import run_async  # noqa: E402

APP_ID = "io.github.maxtubeplus.Desktop"

NAV = [
    ("search", "Search", "system-search-symbolic"),
    ("subscriptions", "Subscriptions", "view-list-bullet-symbolic"),
    ("downloads", "Downloads", "folder-download-symbolic"),
    ("comments", "Commented videos", "mail-unread-symbolic"),
    ("bans", "Banned creators", "action-unavailable-symbolic"),
]


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="MaxTubePlus", default_width=1180, default_height=780)
        self.set_size_request(360, 480)
        self.store = app.store
        self.downloads = app.downloads
        self._menu_item = None

        self.toasts = Adw.ToastOverlay()
        self.split = Adw.NavigationSplitView(min_sidebar_width=210, max_sidebar_width=260)
        self.toasts.set_child(self.split)
        self.set_content(self.toasts)

        # Sidebar
        sidebar_header = Adw.HeaderBar()
        menu = Gio.Menu()
        menu.append("Preferences", "app.preferences")
        menu.append("About MaxTubePlus", "app.about")
        sidebar_header.pack_end(Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu, primary=True, tooltip_text="Main menu"))
        self.nav_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.nav_list.add_css_class("navigation-sidebar")
        for tag, title, icon in NAV:
            row = Gtk.ListBoxRow()
            row.tag = tag
            box = Gtk.Box(spacing=12, margin_top=6, margin_bottom=6, margin_start=6)
            box.append(Gtk.Image(icon_name=icon))
            box.append(Gtk.Label(label=title, xalign=0))
            row.set_child(box)
            self.nav_list.append(row)
        self.nav_list.connect("row-activated", lambda _l, row: self.show_page(row.tag))
        sidebar_view = Adw.ToolbarView(content=Gtk.ScrolledWindow(child=self.nav_list, vexpand=True))
        sidebar_view.add_top_bar(sidebar_header)
        self.split.set_sidebar(Adw.NavigationPage(title="MaxTubePlus", child=sidebar_view))

        # Pages
        self.search_page = SearchPage(self)
        self.pages = {
            "search": self.search_page,
            "subscriptions": SubscriptionsPage(self),
            "downloads": DownloadsPage(self),
            "comments": CommentsPage(self),
            "bans": BansPage(self),
        }
        self._install_actions()
        self.show_page("search")

        # Narrow windows collapse the sidebar (phones / tiling layouts).
        breakpoint = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 640sp"))
        breakpoint.add_setter(self.split, "collapsed", True)
        self.add_breakpoint(breakpoint)

    # --- navigation ------------------------------------------------------
    def show_page(self, tag):
        page = self.pages[tag]
        if self.split.get_content() is not page:
            self.split.set_content(page)
        self.split.set_show_content(True)
        for row in self._nav_rows():
            if row.tag == tag:
                self.nav_list.select_row(row)
        if tag == "subscriptions" and not page.loaded:
            page.refresh()
        if tag == "downloads":
            page.reload()

    def _nav_rows(self):
        row = self.nav_list.get_first_child()
        while row is not None:
            yield row
            row = row.get_next_sibling()

    def show_filters(self):
        FiltersDialog(self).present(self)

    def show_channels(self):
        ChannelsDialog(self).present(self)

    def toast(self, message):
        self.toasts.add_toast(Adw.Toast(title=GLib.markup_escape_text(message), timeout=4))

    # --- item actions ----------------------------------------------------
    def set_menu_item(self, item):
        self._menu_item = item

    def item_menu(self, item):
        menu = Gio.Menu()
        if item.kind in ("video", "short"):
            menu.append("Play", "win.item-play")
            menu.append("Download", "win.item-download")
            menu.append("Download audio only", "win.item-download-audio")
        if item.channel_id:
            menu.append("Unsubscribe" if self.store.is_subscribed(item.channel_id) else "Subscribe", "win.item-subscribe")
        if item.handle or item.channel_id:
            menu.append("Ban creator", "win.item-ban")
        menu.append("Open in browser", "win.item-browser")
        menu.append("Copy link", "win.item-copy")
        return menu

    def _install_actions(self):
        def add(name, callback):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda *_: callback())
            self.add_action(action)

        add("item-play", lambda: self._menu_item and self.open_item(self._menu_item))
        add("item-download", lambda: self._menu_item and self.download(self._menu_item))
        add("item-download-audio", lambda: self._menu_item and self.download(self._menu_item, audio_only=True))
        add("item-subscribe", lambda: self._menu_item and self.toggle_subscription(self._menu_item))
        add("item-ban", lambda: self._menu_item and self.ban_item(self._menu_item))
        add("item-browser", lambda: self._menu_item and self.open_uri(self._menu_item.url))
        add("item-copy", lambda: self._menu_item and (Gdk.Display.get_default().get_clipboard().set(self._menu_item.url), self.toast("Link copied")))
        add("import-takeout", self.import_takeout)
        add("my-activity", lambda: self.open_uri("https://myactivity.google.com/page?page=youtube_comments"))
        add("takeout-help", self.takeout_help)
        add("clear-comments", self.clear_comments)

    def open_item(self, item):
        if item.kind == "channel":
            self.open_uri(item.url)
        else:
            self.play_url(item.url)

    def play_url(self, url):
        command = (self.store.get("player.command") or "mpv").split()
        if not shutil.which(command[0]):
            self.toast(f"{command[0]} is not installed — install mpv (pacman -S mpv) or set a player in Preferences")
            self.open_uri(url)
            return
        subprocess.Popen(command + ["--force-window=immediate", url] if command[0] == "mpv" else command + [url],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def play_file(self, path):
        self.play_url(path)

    def open_uri(self, uri):
        Gtk.UriLauncher.new(uri).launch(self, None, None, None)

    def show_in_folder(self, path):
        Gtk.FileLauncher.new(Gio.File.new_for_path(path)).open_containing_folder(self, None, None, None)

    def download(self, item, audio_only=False):
        if audio_only and not self.store.get("downloads.audioOnly"):
            self.store.settings["downloads.audioOnly"] = True
            self.downloads.enqueue(item.id, item.title, item.channel)
            self.store.settings["downloads.audioOnly"] = False
        else:
            self.downloads.enqueue(item.id, item.title, item.channel)
        self.toast("Download queued")

    def toggle_subscription(self, item):
        if self.store.is_subscribed(item.channel_id):
            self.store.unsubscribe(item.channel_id)
            self.toast(f"Unsubscribed from {item.channel}")
        else:
            self.store.subscribe(item.channel_id, item.channel or item.title, item.handle or None)
            self.toast(f"Subscribed to {item.channel or item.title}")

    def subscribe_handle(self, text):
        run_async(lambda: youtube.resolve_handle(text),
                  lambda r: (self.store.subscribe(r[0], r[1] or "@" + r[2], r[2]), self.toast(f"Subscribed to {r[1] or '@' + r[2]}")),
                  lambda e: self.toast(str(e)))

    def ban_item(self, item):
        handle = item.handle
        if handle:
            self.store.ban(handle, item.channel_id or None, item.channel or None)
            self.toast(f"Banned {item.channel or '@' + handle}")
        elif item.channel_id:
            # No handle on this result: resolve via the channel ID's page name.
            self.store.ban(item.channel_id.lower(), item.channel_id, item.channel or None)
            self.toast(f"Banned {item.channel}")

    def ban_handle(self, text):
        handle = youtube.normalize_handle(text)
        if not handle:
            self.toast("Enter a YouTube handle like @channelname (3–30 letters, digits, _ - .).")
            return
        self.store.ban(handle)  # hidden by handle immediately

        def done(result):
            channel_id, name, handle = result
            self.store.ban(handle, channel_id, name)
            self.toast(f"Banned {name or '@' + handle}")

        run_async(lambda: youtube.resolve_handle(handle), done,
                  lambda e: self.toast(f"{e} — still hidden by handle; will match by name once found"))

    def search_term(self, term):
        if term.startswith("#") and len(term) > 1:
            self.open_uri("https://www.youtube.com/hashtag/" + GLib.uri_escape_string(term[1:], None, False))
            return
        self.show_page("search")
        self.search_page.run(term)

    # --- commented videos ----------------------------------------------
    def import_takeout(self):
        dialog = Gtk.FileDialog(title="Import Google Takeout comments")
        filters = Gio.ListStore.new(Gtk.FileFilter)
        file_filter = Gtk.FileFilter(name="Takeout comments (CSV, HTML)")
        for pattern in ("*.csv", "*.html", "*.htm"):
            file_filter.add_pattern(pattern)
        filters.append(file_filter)
        dialog.set_filters(filters)

        def chosen(dlg, result):
            try:
                file = dlg.open_finish(result)
            except GLib.Error:
                return
            try:
                added = takeout.import_file(self.store, file.get_path())
                self.toast(f"Imported {added} new comment{'s' if added != 1 else ''}")
            except (ValueError, OSError) as error:
                self.toast(str(error))
            self.pages["comments"].reload()

        dialog.open(self, None, chosen)

    def takeout_help(self):
        dialog = Adw.AlertDialog(
            heading="Export your comments",
            body="1. Open takeout.google.com\n2. Deselect all, select “YouTube and YouTube Music”\n3. Under “All YouTube data included” keep “comments”\n"
                 "4. Export, download, unzip\n5. Import YouTube and YouTube Music/comments/comments.csv\n\n"
                 "YouTube has no comment-history API, so this export is the complete source. Your file is parsed on this computer and never uploaded.")
        dialog.add_response("ok", "OK")
        dialog.present(self)

    def clear_comments(self):
        self.store.comments = {"records": [], "lastImport": None}
        self.store.save("comments")
        self.pages["comments"].reload()


class MaxTubePlusApp(Adw.Application):
    def __init__(self, self_test=False):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE if self_test else Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.self_test = self_test
        self.exit_code = 0
        self.store = Store()
        self.downloads = None
        self.window = None
        for name, callback in (("preferences", self.on_preferences), ("about", self.on_about), ("quit", lambda: self.quit())):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda *_a, cb=callback: cb())
            self.add_action(action)
        self.set_accels_for_action("app.quit", ["<Control>q"])
        self.set_accels_for_action("app.preferences", ["<Control>comma"])

    def do_activate(self):
        if self.window is None:
            self.downloads = DownloadManager(self.store, on_change=self._download_changed, on_notify=self._notify)
            self.window = MainWindow(self)
            self.hold()  # downloads keep running when the window is closed
            self.window.connect("close-request", self._on_close)
            if self.downloads.recovered:
                self.window.toast(f"Resuming {self.downloads.recovered} interrupted download{'s' if self.downloads.recovered != 1 else ''}")
            self.downloads.pump()
        self.window.present()
        if self.self_test:
            GLib.timeout_add(300, self._run_self_test)

    def _on_close(self, window):
        active = any(i["state"] in ("downloading", "queued") for i in self.downloads.items)
        if active and not self.self_test:
            window.set_visible(False)  # keep downloading in the background
            self._notify("Downloads continue in the background", "Open MaxTubePlus again to see progress.")
            return True
        self.downloads.shutdown()
        services.flush_caches()
        self.release()
        return False

    def _download_changed(self, _item):
        GLib.idle_add(lambda: (self.window and self.window.pages["downloads"].reload(), False)[1])

    def _notify(self, title, body):
        notification = Gio.Notification.new(title)
        notification.set_body(body)
        GLib.idle_add(lambda: (self.send_notification(None, notification), False)[1])

    def on_preferences(self):
        PreferencesDialog(self.window).present(self.window)

    def on_about(self):
        about = Adw.AboutDialog(
            application_name="MaxTubePlus", application_icon=APP_ID, version=__version__,
            developer_name="MaxTubePlus contributors", license_type=Gtk.License.CUSTOM,
            license="Based on MaxTube by Mark02-2012 and the MaxTubePlus iOS tweak. Not affiliated with Google or YouTube.",
            website="https://github.com/trail-b1az3r/Maxtubeplus-",
            comments="A desktop YouTube client with MaxTubePlus's advanced search, banned creators, DeArrow and background downloads.")
        about.add_credit_section("Services", ["DeArrow by Ajay Ramachandran (CC BY-NC-SA 4.0 data) https://dearrow.ajay.app",
                                              "Return YouTube Dislike https://returnyoutubedislike.com",
                                              "yt-dlp https://github.com/yt-dlp/yt-dlp", "mpv https://mpv.io"])
        about.present(self.window)

    def _run_self_test(self):
        """Builds every page and dialog under a real display (Xvfb in CI)."""
        try:
            for tag, _title, _icon in NAV:
                self.window.show_page(tag)
            for dialog_class in (FiltersDialog, ChannelsDialog, PreferencesDialog):
                dialog = dialog_class(self.window)
                dialog.present(self.window)
                dialog.close()
            self.window.search_page.reapply()
            filtering.active_filter_descriptions(self.store)
            print("self-test: all pages and dialogs built", flush=True)
        except Exception as error:  # report and fail
            import traceback
            traceback.print_exc()
            print(f"self-test FAILED: {error}", file=sys.stderr, flush=True)
            self.exit_code = 1
        self.downloads.shutdown()
        self.quit()
        return False


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)
    self_test = "--self-test" in argv
    if self_test:
        argv.remove("--self-test")  # XDG dirs were redirected in __main__ before import
    app = MaxTubePlusApp(self_test=self_test)
    code = app.run(argv)
    return app.exit_code or code
