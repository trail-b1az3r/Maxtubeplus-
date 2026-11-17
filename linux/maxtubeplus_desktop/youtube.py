"""YouTube data without an account: YouTube's public web endpoints.

* search      - youtubei/v1/search (the request youtube.com makes), with the
                same `sp` filter params the iOS tweak generates
* resolve     - youtubei/v1/navigation/resolve_url + browse for @handles
* channel feed - the public per-channel RSS feed (Subscriptions page)
Playback and downloads go through yt-dlp / mpv, not this module.
"""
import calendar
import json
import re
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

from . import core

USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
CLIENT = {"clientName": "WEB", "clientVersion": "2.20251101.00.00", "hl": "en", "gl": "US"}


class YouTubeError(Exception):
    pass


@dataclass
class Item:
    kind: str                     # "video" | "short" | "channel" | "playlist"
    id: str
    title: str = ""
    channel: str = ""
    channel_id: str = ""
    handle: str = ""              # lowercase, no "@"
    duration: int = -1            # seconds
    age: int = -1                 # seconds since upload (approximate, from "3 days ago")
    published: str = ""           # as YouTube wrote it
    views: int = -1
    thumbnail: str = ""
    snippet: str = ""             # description snippet / extra text
    published_unix: int = -1      # exact, when known (RSS)
    likes: int = -1               # filled from RYD when needed
    extra: dict = field(default_factory=dict)

    @property
    def url(self):
        if self.kind == "channel":
            return f"https://www.youtube.com/channel/{self.id}"
        if self.kind == "playlist":
            return f"https://www.youtube.com/playlist?list={self.id}"
        if self.kind == "short":
            return f"https://www.youtube.com/shorts/{self.id}"
        return f"https://www.youtube.com/watch?v={self.id}"

    def searchable_text(self):
        return "\n".join(x for x in (self.title, self.snippet, self.channel, "@" + self.handle if self.handle else "") if x)


def _post(path, body, timeout=20):
    body = dict(body, context={"client": CLIENT})
    request = urllib.request.Request(
        f"https://www.youtube.com/youtubei/v1/{path}?prettyPrint=false",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise YouTubeError(f"YouTube returned HTTP {error.code}") from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise YouTubeError(f"Couldn't reach YouTube ({error})") from error


def _text(obj):
    if not obj:
        return ""
    if "simpleText" in obj:
        return obj["simpleText"]
    if "content" in obj:
        return obj["content"]
    return "".join(run.get("text", "") for run in obj.get("runs", []))


def _handle_from_url(url):
    match = re.search(r"/@([^/?#]+)", url or "")
    return urllib.parse.unquote(match.group(1)).lower() if match else ""


def _best_thumb(thumbnails):
    thumbs = (thumbnails or {}).get("thumbnails") or thumbnails or []
    if isinstance(thumbs, list) and thumbs:
        url = thumbs[-1].get("url", "")
        return "https:" + url if url.startswith("//") else url
    return ""


def _walk(obj):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from _walk(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _walk(value)


def _video_item(v):
    owner = (v.get("ownerText") or v.get("longBylineText") or {}).get("runs", [{}])[0]
    browse = owner.get("navigationEndpoint", {}).get("browseEndpoint", {})
    published = _text(v.get("publishedTimeText"))
    snippets = v.get("detailedMetadataSnippets") or []
    snippet = _text(snippets[0].get("snippetText")) if snippets else _text(v.get("descriptionSnippet"))
    length = _text(v.get("lengthText"))
    return Item(
        kind="video", id=v.get("videoId", ""), title=_text(v.get("title")),
        channel=owner.get("text", ""), channel_id=browse.get("browseId", ""),
        handle=_handle_from_url(browse.get("canonicalBaseUrl")),
        duration=core.parse_duration(length) if length else -1,
        age=core.parse_relative_age(published) if published else -1, published=published,
        views=core.parse_count(_text(v.get("viewCountText"))), thumbnail=_best_thumb(v.get("thumbnail")),
        snippet=snippet,
    )


def _short_item(node):
    """reelItemRenderer (older) or shortsLockupViewModel (current)."""
    if "videoId" in node:  # reelItemRenderer
        return Item(kind="short", id=node["videoId"], title=_text(node.get("headline")),
                    views=core.parse_count(_text(node.get("viewCountText"))), thumbnail=_best_thumb(node.get("thumbnail")))
    entity = node.get("entityId", "")
    video_id = ""
    for d in _walk(node):
        if isinstance(d.get("reelWatchEndpoint"), dict) and d["reelWatchEndpoint"].get("videoId"):
            video_id = d["reelWatchEndpoint"]["videoId"]
            break
    video_id = video_id or entity.replace("shorts-shelf-item-", "")
    overlay = node.get("overlayMetadata", {})
    title = (overlay.get("primaryText") or {}).get("content", "")
    return Item(kind="short", id=video_id, title=title, views=core.parse_count((overlay.get("secondaryText") or {}).get("content", "")),
                thumbnail=_best_thumb((node.get("thumbnail") or {}).get("sources") and {"thumbnails": node["thumbnail"]["sources"]}))


def _channel_item(c):
    browse = c.get("navigationEndpoint", {}).get("browseEndpoint", {})
    handle = _handle_from_url(browse.get("canonicalBaseUrl"))
    if not handle:
        sub = _text(c.get("subscriberCountText"))
        handle = sub[1:].lower() if sub.startswith("@") else ""
    return Item(kind="channel", id=c.get("channelId", ""), title=_text(c.get("title")), channel=_text(c.get("title")),
                channel_id=c.get("channelId", ""), handle=handle, snippet=_text(c.get("descriptionSnippet")),
                thumbnail=_best_thumb(c.get("thumbnail")))


def parse_search_response(data):
    """Returns (items, continuation_token) from a search or continuation response."""
    items, seen = [], set()
    for node in _walk(data):
        item = None
        if "videoRenderer" in node:
            item = _video_item(node["videoRenderer"])
        elif "reelItemRenderer" in node:
            item = _short_item(node["reelItemRenderer"])
        elif "shortsLockupViewModel" in node:
            item = _short_item(node["shortsLockupViewModel"])
        elif "channelRenderer" in node:
            item = _channel_item(node["channelRenderer"])
        if item and item.id and (item.kind, item.id) not in seen:
            seen.add((item.kind, item.id))
            items.append(item)
    token = None
    for node in _walk(data):
        command = node.get("continuationCommand") if isinstance(node, dict) else None
        if isinstance(command, dict) and command.get("token"):
            token = command["token"]
    return items, token


def search(query, params="", continuation=None):
    if continuation:
        data = _post("search", {"continuation": continuation})
    else:
        body = {"query": query}
        if params:
            body["params"] = params
        data = _post("search", body)
    return parse_search_response(data)


def resolve_handle(handle):
    """'@name' / 'name' / channel URL -> (channel_id, display_name, handle)."""
    handle = normalize_handle(handle)
    if not handle:
        raise YouTubeError("Enter a YouTube handle like @channelname (3–30 letters, digits, _ - .).")
    data = _post("navigation/resolve_url", {"url": f"https://www.youtube.com/@{handle}"})
    channel_id = (data.get("endpoint", {}).get("browseEndpoint") or {}).get("browseId", "")
    if not channel_id.startswith("UC"):
        raise YouTubeError(f"@{handle} does not exist")
    name = ""
    try:
        meta = _post("browse", {"browseId": channel_id}).get("metadata", {}).get("channelMetadataRenderer", {})
        name = meta.get("title", "")
    except YouTubeError:
        pass
    return channel_id, name, handle


def normalize_handle(text):
    text = (text or "").strip()
    if "@" in text:
        text = text[text.rindex("@") + 1:]
    text = re.split(r"[/?#\s]", text)[0].lower()
    return text if re.fullmatch(r"[a-z0-9_.\-]{3,30}", text) else ""


def channel_feed(channel_id):
    """Latest uploads from the public RSS feed (exact publish times)."""
    url = f"https://www.youtube.com/feeds/videos.xml?channel_id={urllib.parse.quote(channel_id)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            root = ET.fromstring(response.read())
    except (urllib.error.URLError, OSError, ET.ParseError) as error:
        raise YouTubeError(f"Couldn't load the channel feed ({error})") from error
    ns = {"a": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015",
          "media": "http://search.yahoo.com/mrss/"}
    channel = root.findtext("a:title", default="", namespaces=ns)
    items = []
    for entry in root.findall("a:entry", ns):
        video_id = entry.findtext("yt:videoId", default="", namespaces=ns)
        published = entry.findtext("a:published", default="", namespaces=ns)
        try:
            unix = calendar.timegm(time.strptime(published[:19], "%Y-%m-%dT%H:%M:%S"))  # feed times are UTC
        except ValueError:
            unix = -1
        link = entry.find("a:link", ns)
        kind = "short" if link is not None and "/shorts/" in link.get("href", "") else "video"
        group = entry.find("media:group", ns)
        thumb = group.find("media:thumbnail", ns).get("url", "") if group is not None and group.find("media:thumbnail", ns) is not None else ""
        description = group.findtext("media:description", default="", namespaces=ns) if group is not None else ""
        items.append(Item(kind=kind, id=video_id, title=entry.findtext("a:title", default="", namespaces=ns), channel=channel,
                          channel_id=channel_id, published_unix=unix, age=int(time.time()) - unix if unix > 0 else -1,
                          published=published[:10], thumbnail=thumb, snippet=description[:300]))
    return items
