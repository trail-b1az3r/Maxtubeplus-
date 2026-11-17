"""Applies MaxTubePlus filters, topics/tags and bans to search/feed items.

Rules match the iOS tweak (AdvancedSearch.x, Bans.x) and use the same C core.
"""
import time

from . import core


def filters_from_store(store):
    f = store.filters
    return core.Filters(
        min_likes=f.get("minLikes", -1), min_duration=f.get("minDuration", -1), max_duration=f.get("maxDuration", -1),
        max_age=f.get("maxAge", -1), uploaded_after=f.get("after", -1), uploaded_before=f.get("before", -1),
        flexible_dates=bool(store.get("search.flexibleDates")),
    )


def has_active_filters(store):
    f = store.filters
    return filters_from_store(store).active_count() > 0 or bool(f.get("include")) or bool(f.get("exclude"))


def server_params(store):
    """YouTube `sp` for the active filters + sort (server narrows, client refines)."""
    if not store.get("search.filters"):
        return ""
    f = store.filters
    max_age = f.get("maxAge", -1)
    after = f.get("after", -1)
    if after > 0:
        since_after = int(time.time()) - after
        max_age = since_after if max_age < 0 else min(max_age, since_after)
    return core.search_params(store.get("search.sortMode") == 1, max_age, f.get("minDuration", -1), f.get("maxDuration", -1))


def _matches_term(text, term, loose):
    if term.startswith("#") or term.startswith("@"):
        return core.contains_token(text, term)
    return core.contains(text, term, loose)


def fails_topics(item, store):
    f = store.filters
    loose = bool(store.get("search.looseNames"))
    text = item.searchable_text()
    for term in f.get("exclude") or []:
        if _matches_term(text, term, loose):
            return True
    include = f.get("include") or []
    if not include:
        return False
    return not any(_matches_term(text, term, loose) for term in include)


def is_banned(item, store):
    """Banned by @handle: matches channel ID, handle, or display name."""
    loose = bool(store.get("search.looseNames"))
    for ban in store.bans:
        if item.channel_id and ban.get("channelId") and item.channel_id == ban["channelId"]:
            return True
        if item.handle and item.handle == ban["handle"]:
            return True
        name = ban.get("name")
        if name and item.channel:
            if (item.channel.lower() == name.lower()) if loose else (item.channel == name):
                return True
        if item.kind == "channel" and item.id == ban.get("channelId"):
            return True
    return False


def evaluate(item, store, now=None):
    """Returns (verdict, reason) where verdict is "show", "hide" or "unknown"
    ("unknown" = a filter needs data not loaded yet, e.g. likes)."""
    if is_banned(item, store):
        return "hide", "banned creator"
    if not store.get("search.filters") or item.kind not in ("video", "short"):
        return "show", ""
    if fails_topics(item, store):
        return "hide", "topics & tags"
    result = filters_from_store(store).evaluate(item.duration, item.likes, item.age, int(now or time.time()))
    if result == core.PASS:
        return "show", ""
    if result == core.UNKNOWN:
        return "unknown", "needs likes"
    reasons = {core.REJECT_LIKES: "too few likes", core.REJECT_SHORT: "too short", core.REJECT_LONG: "too long",
               core.REJECT_AGE: "too old", core.REJECT_WINDOW: "outside upload dates"}
    return "hide", reasons.get(result, "filtered")


def sort_items(items, store):
    """Recency: newest first, unknown ages last, otherwise server (relevance) order."""
    if store.get("search.sortMode") != 1:
        return items
    indexed = list(enumerate(items))
    indexed.sort(key=lambda pair: (pair[1].age < 0, pair[1].age if pair[1].age >= 0 else 0, pair[0]))
    return [item for _, item in indexed]


FILTER_LABELS = {
    "minLikes": lambda v: f"≥ {v:,} likes",
    "minDuration": lambda v: f"Longer than {v // 60}:{v % 60:02d}",
    "maxDuration": lambda v: f"Shorter than {v // 60}:{v % 60:02d}",
    "maxAge": lambda v: "Uploaded " + ("last hour" if v <= 3600 else "today" if v <= 86400 else "this week" if v <= 7 * 86400
                                       else "this month" if v <= 31 * 86400 else "this year" if v <= 366 * 86400 else f"last {v // 86400} days"),
}


def active_filter_descriptions(store):
    """[(key, text)] for the "Active filters" list (each removable individually)."""
    f = store.filters
    out = []
    for key in ("minLikes", "minDuration", "maxDuration", "maxAge"):
        if f.get(key, -1) >= 0:
            out.append((key, FILTER_LABELS[key](f[key])))
    if f.get("after", -1) >= 0 or f.get("before", -1) >= 0:
        fmt = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
        a = fmt(f["after"]) if f.get("after", -1) >= 0 else "…"
        b = fmt(f["before"]) if f.get("before", -1) >= 0 else "now"
        approx = " (approx.)" if store.get("search.flexibleDates") else ""
        out.append(("window", f"Uploaded {a} – {b}{approx}"))
    parts = []
    if f.get("include"):
        parts.append("Topics: " + ", ".join(f["include"]))
    if f.get("exclude"):
        parts.append("Excluding: " + ", ".join(f["exclude"]))
    if parts:
        out.append(("topics", " · ".join(parts)))
    return out


def remove_filter(store, key):
    f = store.filters
    if key == "window":
        f["after"] = f["before"] = -1
    elif key == "topics":
        f["include"], f["exclude"] = [], []
    else:
        f[key] = -1
    store.save("filters")


def clear_filters(store):
    """Clears every filter; sort mode is intentionally preserved (as on iOS)."""
    from .store import DEFAULT_FILTERS
    store.filters = {k: (list(v) if isinstance(v, list) else v) for k, v in DEFAULT_FILTERS.items()}
    store.save("filters")
