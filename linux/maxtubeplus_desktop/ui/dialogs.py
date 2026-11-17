"""Dialogs: search filters (same sections and copy as the iOS panel),
subscribed channels, and preferences."""
import time
from datetime import datetime

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

from .. import filtering  # noqa: E402

AGES = [("Any", -1), ("Last hour", 3600), ("Today", 86400), ("This week", 7 * 86400),
        ("This month", 31 * 86400), ("This year", 366 * 86400)]
MAX_MINUTES = 120  # slider end = no upper bound


def _date_to_unix(text, end_of_day=False):
    text = text.strip()
    if not text:
        return -1
    try:
        day = datetime.strptime(text, "%Y-%m-%d")
    except ValueError:
        return None
    unix = int(time.mktime(day.timetuple()))
    return unix + 86399 if end_of_day else unix


def _unix_to_date(value):
    return time.strftime("%Y-%m-%d", time.localtime(value)) if value and value >= 0 else ""


class FiltersDialog(Adw.PreferencesDialog):
    def __init__(self, window):
        super().__init__(title="Search filters", search_enabled=False)
        self.window, self.store = window, window.store
        self.set_content_width(560)
        self.page = Adw.PreferencesPage()
        self.add(self.page)
        self._groups = []
        self.build()

    def _add_group(self, group):
        self._groups.append(group)
        self.page.add(group)

    def build(self):
        for group in self._groups:
            self.page.remove(group)
        self._groups = []
        s, f = self.store, self.store.filters

        # Header buttons live in a group at the top (PreferencesDialog has no header API).
        actions = Adw.PreferencesGroup()
        bar = Gtk.Box(spacing=12, halign=Gtk.Align.END)
        clear = Gtk.Button(label="Clear All", sensitive=filtering.has_active_filters(s))
        clear.connect("clicked", lambda *_: (filtering.clear_filters(s), self.build()))
        query = self.window.search_page.query
        apply = Gtk.Button(label="Apply" if query else "Done")
        apply.add_css_class("suggested-action")
        apply.connect("clicked", lambda *_: self.apply())
        bar.append(clear)
        bar.append(apply)
        actions.add(bar)
        self._add_group(actions)

        active = Adw.PreferencesGroup(title="Active filters", description="Tap a filter to remove it. Filters stay active when you change the sort order.")
        descriptions = filtering.active_filter_descriptions(s)
        if not descriptions:
            active.add(Adw.ActionRow(title="No filters"))
        for key, text in descriptions:
            row = Adw.ActionRow(title=text, activatable=True)
            row.add_suffix(Gtk.Image(icon_name="window-close-symbolic"))
            row.connect("activated", lambda _r, k=key: (filtering.remove_filter(s, k), self.build()))
            active.add(row)
        self._add_group(active)

        sort = Adw.PreferencesGroup(title="Sort", description="Recency asks YouTube to sort by upload date; your filters are sent along with it.")
        sort_row = Adw.ComboRow(title="Order", model=Gtk.StringList.new(["Relevance", "Recency"]), selected=1 if s.get("search.sortMode") == 1 else 0)
        sort_row.connect("notify::selected", lambda r, _p: s.set("search.sortMode", int(r.get_selected())))
        sort.add(sort_row)
        self._add_group(sort)

        duration = Adw.PreferencesGroup(title="Duration")
        low = f.get("minDuration", -1)
        high = f.get("maxDuration", -1)
        self.min_scale = self._scale(0 if low < 0 else low / 60)
        self.max_scale = self._scale(MAX_MINUTES if high < 0 else min(high / 60, MAX_MINUTES))
        self.duration_label = Gtk.Label(xalign=0)
        self.duration_label.add_css_class("dim-label")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin_top=8, margin_bottom=8, margin_start=12, margin_end=12)
        box.append(self.duration_label)
        for title, scale in (("Minimum", self.min_scale), ("Maximum", self.max_scale)):
            line = Gtk.Box(spacing=8)
            line.append(Gtk.Label(label=title, width_chars=8, xalign=0))
            line.append(scale)
            box.append(line)
        self.min_scale.connect("value-changed", lambda *_: self._duration_changed(True))
        self.max_scale.connect("value-changed", lambda *_: self._duration_changed(False))
        duration_row = Adw.PreferencesRow(child=box, activatable=False)
        duration.add(duration_row)
        self._update_duration_label()
        self._add_group(duration)

        likes = Adw.PreferencesGroup(title="Minimum likes", description="Search results don't include like counts, so they are looked up from the Return YouTube Dislike API (returnyoutubedislikeapi.com). Results are shown until their count is known.")
        likes_row = Adw.SpinRow.new_with_range(0, 1_000_000_000, 1000)
        likes_row.set_title("Minimum likes (0 = off)")
        likes_row.set_value(max(f.get("minLikes", -1), 0))
        likes_row.connect("notify::value", lambda r, _p: self._set_filter("minLikes", int(r.get_value()) or -1, rebuild=False))
        likes.add(likes_row)
        self._add_group(likes)

        date = Adw.PreferencesGroup(title="Upload date", description="YouTube narrows results to the nearest server bucket (hour/day/week/month/year); MaxTubePlus then applies the exact range using the upload age shown on each result.")
        ages = [value for _, value in AGES]
        recency = Adw.ComboRow(title="Uploaded", model=Gtk.StringList.new([label for label, _ in AGES]),
                               selected=ages.index(f.get("maxAge", -1)) if f.get("maxAge", -1) in ages else 0)
        recency.connect("notify::selected", lambda r, _p: self._set_filter("maxAge", ages[r.get_selected()], rebuild=False))
        date.add(recency)
        for key, title, end in (("after", "Uploaded after (YYYY-MM-DD)", False), ("before", "Uploaded before (YYYY-MM-DD)", True)):
            row = Adw.EntryRow(title=title, text=_unix_to_date(f.get(key, -1)), show_apply_button=True)
            row.connect("apply", lambda r, k=key, e=end: self._set_date(r, k, e))
            date.add(row)
        self._add_group(date)

        matching = Adw.PreferencesGroup(title="Matching", description="Flexible dates: upload-date and recency filters keep results that are close to the range (YouTube only shows rough ages like \"1 year ago\"). Loose names: topics, tags, banned names and commented-video search ignore upper/lower case and tolerate small typos.")
        for key, title in (("search.flexibleDates", "Flexible dates (don't require exact dates)"), ("search.looseNames", "Loose names (don't require exact names)")):
            row = Adw.SwitchRow(title=title, active=bool(s.get(key)))
            row.connect("notify::active", lambda r, _p, k=key: s.set(k, r.get_active()))
            matching.add(row)
        self._add_group(matching)

        topics = Adw.PreferencesGroup(title="Topics &amp; tags", description="Results must mention at least one included topic and none of the excluded ones (title, description snippet, #hashtags). Start a #tag to match whole hashtags.")
        self.term_mode = Gtk.DropDown.new_from_strings(["Include", "Exclude"])
        self.term_mode.set_valign(Gtk.Align.CENTER)
        term_row = Adw.EntryRow(title="Topic, keyword or #tag", show_apply_button=True)
        term_row.add_suffix(self.term_mode)
        term_row.connect("apply", lambda r: self._add_term(r))
        topics.add(term_row)
        for term, excluded in [(t, False) for t in f.get("include") or []] + [(t, True) for t in f.get("exclude") or []]:
            row = Adw.ActionRow(title=term, subtitle="Excluded" if excluded else "Included")
            search_button = Gtk.Button(icon_name="system-search-symbolic", tooltip_text="Search YouTube for this", valign=Gtk.Align.CENTER)
            search_button.add_css_class("flat")
            search_button.connect("clicked", lambda *_, t=term: (self.close(), self.window.search_term(t)))
            remove = Gtk.Button(icon_name="user-trash-symbolic", tooltip_text="Remove", valign=Gtk.Align.CENTER)
            remove.add_css_class("flat")
            remove.connect("clicked", lambda *_, t=term: self._remove_term(t))
            row.add_suffix(search_button)
            row.add_suffix(remove)
            topics.add(row)
        self._add_group(topics)

        bans = Adw.PreferencesGroup(title="Banned creators", description="Everything from a banned creator — videos, Shorts and channel results — is hidden, and the next item takes its place.")
        ban_row = Adw.EntryRow(title="@handle", show_apply_button=True)
        ban_row.connect("apply", lambda r: (self.window.ban_handle(r.get_text()), r.set_text("")))
        bans.add(ban_row)
        count = len(s.bans)
        manage = Adw.ActionRow(title=f"{count} banned creator{'s' if count != 1 else ''}", activatable=True)
        manage.add_suffix(Gtk.Image(icon_name="go-next-symbolic"))
        manage.connect("activated", lambda *_: (self.close(), self.window.show_page("bans")))
        bans.add(manage)
        self._add_group(bans)

    def _scale(self, value):
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, MAX_MINUTES, 1)
        scale.set_hexpand(True)
        scale.set_draw_value(False)
        scale.set_value(value)
        return scale

    def _duration_changed(self, low_moved):
        low, high = self.min_scale.get_value(), self.max_scale.get_value()
        if low > high:  # keep the two thumbs ordered, like the iOS range slider
            (self.max_scale if low_moved else self.min_scale).set_value(low if low_moved else high)
            return
        self._update_duration_label()
        f = self.store.filters
        f["minDuration"] = -1 if low <= 0 else int(low * 60)
        f["maxDuration"] = -1 if high >= MAX_MINUTES else int(high * 60)
        self.store.save("filters")

    def _update_duration_label(self):
        low, high = self.min_scale.get_value(), self.max_scale.get_value()
        lo = "Any" if low <= 0 else f"{low:.0f} min"
        hi = "Any" if high >= MAX_MINUTES else f"{high:.0f} min"
        self.duration_label.set_label(f"Minimum: {lo}   Maximum: {hi}")

    def _set_filter(self, key, value, rebuild=True):
        self.store.filters[key] = value
        self.store.save("filters")
        if rebuild:
            self.build()

    def _set_date(self, row, key, end_of_day):
        value = _date_to_unix(row.get_text(), end_of_day)
        if value is None:
            self.window.toast("Use the date format YYYY-MM-DD")
            return
        self._set_filter(key, value)

    def _add_term(self, row):
        term = row.get_text().strip()
        if len(term) < 2:
            return
        f = self.store.filters
        f["include"] = [t for t in f.get("include") or [] if t.lower() != term.lower()]
        f["exclude"] = [t for t in f.get("exclude") or [] if t.lower() != term.lower()]
        f["exclude" if self.term_mode.get_selected() == 1 else "include"].append(term)
        self.store.save("filters")
        self.build()

    def _remove_term(self, term):
        f = self.store.filters
        f["include"] = [t for t in f.get("include") or [] if t != term]
        f["exclude"] = [t for t in f.get("exclude") or [] if t != term]
        self.store.save("filters")
        self.build()

    def apply(self):
        self.close()
        page = self.window.search_page
        query = page.query or " ".join(self.store.filters.get("include") or [])
        if query:
            self.window.show_page("search")
            page.run(query)
        else:
            self.window.toast("Filters saved — they apply to your next search.")


class ChannelsDialog(Adw.PreferencesDialog):
    """Local subscriptions: add by @handle, remove."""

    def __init__(self, window):
        super().__init__(title="Subscribed channels")
        self.window, self.store = window, window.store
        self.page = Adw.PreferencesPage()
        self.add(self.page)
        add = Adw.PreferencesGroup(title="Add a channel", description="Subscriptions are stored on this computer only and need no Google account.")
        entry = Adw.EntryRow(title="@handle", show_apply_button=True)
        entry.connect("apply", lambda r: (self.window.subscribe_handle(r.get_text()), r.set_text("")))
        add.add(entry)
        self.page.add(add)
        self.group = Adw.PreferencesGroup(title="Channels")
        self.page.add(self.group)
        self.rows = []
        listener = lambda name: name == "subscriptions" and self.reload()
        self.store.listen(listener)
        self.connect("closed", lambda *_: self.store.unlisten(listener))
        self.reload()

    def reload(self):
        for row in self.rows:
            self.group.remove(row)
        self.rows = []
        for sub in self.store.subscriptions:
            row = Adw.ActionRow(title=sub.get("name") or sub["channelId"], subtitle="@" + sub["handle"] if sub.get("handle") else sub["channelId"])
            remove = Gtk.Button(label="Unsubscribe", valign=Gtk.Align.CENTER)
            remove.connect("clicked", lambda *_, c=sub["channelId"]: self.store.unsubscribe(c))
            row.add_suffix(remove)
            self.rows.append(row)
            self.group.add(row)
        if not self.rows:
            empty = Adw.ActionRow(title="No channels yet")
            self.rows.append(empty)
            self.group.add(empty)


class PreferencesDialog(Adw.PreferencesDialog):
    """Same groups and wording as Settings › MaxTubePlus on iOS, where they apply on desktop."""

    def __init__(self, window):
        super().__init__(title="Preferences")
        self.window, s = window, window.store

        def switch(group, key, title, subtitle=None):
            row = Adw.SwitchRow(title=title, active=bool(s.get(key)))
            if subtitle:
                row.set_subtitle(subtitle)
            row.connect("notify::active", lambda r, _p: s.set(key, r.get_active()))
            group.add(row)

        def choice(group, key, title, values, labels):
            current = s.get(key)
            row = Adw.ComboRow(title=title, model=Gtk.StringList.new(labels), selected=values.index(current) if current in values else 0)
            row.connect("notify::selected", lambda r, _p: s.set(key, values[r.get_selected()]))
            group.add(row)

        downloads = Adw.PreferencesPage(title="Background Downloads", icon_name="folder-download-symbolic")
        g = Adw.PreferencesGroup(description="Downloads use yt-dlp, keep running in the background, and resume after MaxTubePlus is closed.")
        choice(g, "downloads.maxHeight", "Video quality", [0, 2160, 1440, 1080, 720, 480, 360], ["Best available", "2160p", "1440p", "1080p", "720p", "480p", "360p"])
        switch(g, "downloads.audioOnly", "Audio only (M4A)")
        switch(g, "downloads.notifications", "Notifications")
        choice(g, "downloads.maxConcurrent", "Simultaneous downloads", [1, 2, 3, 4], ["1", "2", "3", "4"])
        choice(g, "downloads.maxRetries", "Automatic retries", [0, 3, 5, 10], ["Off", "3", "5", "10"])
        folder = Adw.EntryRow(title="Download folder (empty = ~/Videos/MaxTubePlus)", text=s.get("downloads.directory") or "", show_apply_button=True)
        folder.connect("apply", lambda r: s.set("downloads.directory", r.get_text().strip()))
        g.add(folder)
        downloads.add(g)
        self.add(downloads)

        dearrow = Adw.PreferencesPage(title="DeArrow", icon_name="font-x-generic-symbolic")
        g = Adw.PreferencesGroup(description="Replaces clickbait titles and thumbnails with community submissions. When a video has no trusted submission, YouTube's original is kept.")
        switch(g, "dearrow.titles", "Replace titles")
        switch(g, "dearrow.thumbnails", "Replace thumbnails", "DeArrow thumbnails are WebP: install webp-pixbuf-loader to see them")
        dearrow.add(g)
        credit = Adw.PreferencesGroup(title="Attribution", description="Titles and thumbnails: DeArrow by Ajay Ramachandran and contributors (dearrow.ajay.app). Database licensed CC BY-NC-SA 4.0. Not affiliated with MaxTubePlus.")
        dearrow.add(credit)
        self.add(dearrow)

        search = Adw.PreferencesPage(title="Advanced Search", icon_name="system-search-symbolic")
        g = Adw.PreferencesGroup(description="Filters combine, can be removed individually, and stay active when the sort order changes.")
        switch(g, "search.filters", "Advanced search filters")
        switch(g, "search.fetchLikes", "Look up like counts (RYD API)")
        switch(g, "search.flexibleDates", "Flexible dates (don't require exact dates)")
        switch(g, "search.looseNames", "Loose names (don't require exact names)")
        search.add(g)
        self.add(search)

        general = Adw.PreferencesPage(title="General", icon_name="preferences-system-symbolic")
        g = Adw.PreferencesGroup(title="Playback", description="Videos open in mpv (it uses yt-dlp to stream from YouTube).")
        player = Adw.EntryRow(title="Player command", text=s.get("player.command") or "mpv", show_apply_button=True)
        player.connect("apply", lambda r: s.set("player.command", r.get_text().strip() or "mpv"))
        g.add(player)
        general.add(g)
        reset = Adw.PreferencesGroup(description="Banned creators, subscriptions, downloads and imported comments are not affected.")
        reset_row = Adw.ButtonRow(title="Reset all MaxTubePlus settings") if hasattr(Adw, "ButtonRow") else Adw.ActionRow(title="Reset all MaxTubePlus settings", activatable=True)
        reset_row.add_css_class("destructive-action")
        reset_row.connect("activated", lambda *_: self._confirm_reset())
        reset.add(reset_row)
        general.add(reset)
        self.add(general)

    def _confirm_reset(self):
        dialog = Adw.AlertDialog(heading="Reset MaxTubePlus settings?", body="Banned creators, subscriptions, downloads and imported comments are not affected.")
        dialog.add_response("cancel", "Cancel")
        dialog.add_response("reset", "Reset")
        dialog.set_response_appearance("reset", Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.connect("response", lambda _d, r: r == "reset" and (self.window.store.reset_settings(), self.close()))
        dialog.present(self)
