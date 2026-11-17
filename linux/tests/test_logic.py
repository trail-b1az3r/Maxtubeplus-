"""Offline tests for the desktop app's logic (no network, no display)."""
import os
import sys
import tempfile
import time
import unittest

_TMP = tempfile.mkdtemp(prefix="mtp-tests-")
for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")):
    os.environ[var] = os.path.join(_TMP, sub)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from maxtubeplus_desktop import core, filtering, services, takeout, youtube  # noqa: E402
from maxtubeplus_desktop.store import Store  # noqa: E402
from maxtubeplus_desktop.youtube import Item  # noqa: E402


def fresh_store():
    return Store(config_dir=tempfile.mkdtemp(dir=_TMP))


SEARCH_FIXTURE = {
    "contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {"contents": [
        {"itemSectionRenderer": {"contents": [
            {"videoRenderer": {
                "videoId": "dQw4w9WgXcQ", "title": {"runs": [{"text": "Learn SwiftUI basics #iOSDev"}]},
                "lengthText": {"simpleText": "12:34"}, "publishedTimeText": {"simpleText": "3 days ago"},
                "viewCountText": {"simpleText": "1,234,567 views"},
                "ownerText": {"runs": [{"text": "Dev Channel", "navigationEndpoint": {"browseEndpoint": {
                    "browseId": "UCuAXFkgsw1L7xaCfnd5JJOw", "canonicalBaseUrl": "/@DevChannel"}}}]},
                "detailedMetadataSnippets": [{"snippetText": {"runs": [{"text": "A beginner tutorial"}]}}],
                "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg"}]}}},
            {"channelRenderer": {"channelId": "UC_x5XG1OV2P6uZZ5FSM9Ttw", "title": {"simpleText": "Google Developers"},
                                 "navigationEndpoint": {"browseEndpoint": {"canonicalBaseUrl": "/@GoogleDevelopers"}}}},
            {"reelItemRenderer": {"videoId": "abcdefghijk", "headline": {"simpleText": "A short"}}},
        ]}},
        {"continuationItemRenderer": {"continuationEndpoint": {"continuationCommand": {"token": "NEXT"}}}},
    ]}}}}
}


class CoreBridgeTests(unittest.TestCase):
    def test_parsing_matches_c_core(self):
        self.assertEqual(core.parse_duration("1:02:03"), 3723)
        self.assertEqual(core.parse_count("1.2K"), 1200)
        self.assertEqual(core.parse_relative_age("3 days ago"), 3 * 86400)
        self.assertTrue(core.is_video_id("dQw4w9WgXcQ"))

    def test_fuzzy_and_tokens(self):
        self.assertTrue(core.contains("Learn SwiftUI basics", "swiftui"))
        self.assertTrue(core.contains("Learn SwiftUI basics", "swfitui", loose=True))
        self.assertFalse(core.contains("Learn SwiftUI basics", "swfitui"))
        self.assertTrue(core.contains_token("with #iOSDev today", "#iosdev"))
        self.assertFalse(core.contains_token("with #iOSDevs today", "#iosdev"))

    def test_search_params_known_values(self):
        self.assertEqual(core.search_params(True), "CAI%3D")
        self.assertEqual(core.search_params(False, max_age=3 * 86400, min_duration=300, max_duration=900), "EgYIAxABGAM%3D")
        self.assertEqual(core.search_params(False), "")

    def test_filter_struct_layout(self):
        f = core.Filters(min_duration=240, max_duration=1200, min_likes=1000, max_age=7 * 86400)
        self.assertEqual(f.active_count(), 4)
        now = 1_700_000_000
        self.assertEqual(f.evaluate(600, 5000, 3 * 86400, now), core.PASS)
        self.assertEqual(f.evaluate(60, 5000, 3 * 86400, now), core.REJECT_SHORT)
        self.assertEqual(f.evaluate(600, -1, 3 * 86400, now), core.UNKNOWN)
        flexible = core.Filters(max_age=7 * 86400, flexible_dates=True)
        self.assertEqual(flexible.evaluate(600, -1, 8 * 86400, now), core.PASS)
        self.assertEqual(core.Filters(max_age=7 * 86400).evaluate(600, -1, 8 * 86400, now), core.REJECT_AGE)


class YouTubeParsingTests(unittest.TestCase):
    def test_search_response(self):
        items, token = youtube.parse_search_response(SEARCH_FIXTURE)
        self.assertEqual(token, "NEXT")
        video, channel, short = items
        self.assertEqual((video.kind, video.id, video.duration, video.age, video.views), ("video", "dQw4w9WgXcQ", 754, 3 * 86400, 1234567))
        self.assertEqual((video.channel, video.channel_id, video.handle), ("Dev Channel", "UCuAXFkgsw1L7xaCfnd5JJOw", "devchannel"))
        self.assertEqual(video.snippet, "A beginner tutorial")
        self.assertEqual((channel.kind, channel.handle), ("channel", "googledevelopers"))
        self.assertEqual((short.kind, short.id), ("short", "abcdefghijk"))

    def test_normalize_handle(self):
        self.assertEqual(youtube.normalize_handle("@Fireship"), "fireship")
        self.assertEqual(youtube.normalize_handle("https://www.youtube.com/@Some.Name/videos"), "some.name")
        self.assertEqual(youtube.normalize_handle("ab"), "")
        self.assertEqual(youtube.normalize_handle("bad handle!"), "bad")  # first token only


class FilteringTests(unittest.TestCase):
    def video(self, **kw):
        base = dict(kind="video", id="dQw4w9WgXcQ", title="Learn SwiftUI basics #iOSDev", channel="Dev Channel",
                    channel_id="UCuAXFkgsw1L7xaCfnd5JJOw", handle="devchannel", duration=600, age=3 * 86400, views=10)
        base.update(kw)
        return Item(**base)

    def test_bans_match_id_handle_and_name(self):
        store = fresh_store()
        self.assertEqual(filtering.evaluate(self.video(), store)[0], "show")
        store.ban("devchannel")
        self.assertEqual(filtering.evaluate(self.video(), store), ("hide", "banned creator"))
        store.unban("devchannel")
        store.ban("other", channel_id="UCuAXFkgsw1L7xaCfnd5JJOw")
        self.assertEqual(filtering.evaluate(self.video(handle=""), store)[0], "hide")
        store.unban("other")
        store.ban("x-name", name="dev channel")
        self.assertEqual(filtering.evaluate(self.video(handle="", channel_id=""), store)[0], "show")
        store.set("search.looseNames", True)
        self.assertEqual(filtering.evaluate(self.video(handle="", channel_id=""), store)[0], "hide")

    def test_topics_and_tags(self):
        store = fresh_store()
        store.filters["include"] = ["swiftui"]
        self.assertEqual(filtering.evaluate(self.video(), store)[0], "show")
        self.assertEqual(filtering.evaluate(self.video(title="Kotlin basics"), store)[0], "hide")
        store.filters["include"], store.filters["exclude"] = [], ["#iosdev"]
        self.assertEqual(filtering.evaluate(self.video(), store), ("hide", "topics & tags"))
        store.filters["exclude"] = ["swfitui"]
        self.assertEqual(filtering.evaluate(self.video(), store)[0], "show")
        store.set("search.looseNames", True)
        self.assertEqual(filtering.evaluate(self.video(), store)[0], "hide")

    def test_filters_and_descriptions(self):
        store = fresh_store()
        store.filters.update(minDuration=900, minLikes=1000)
        self.assertEqual(filtering.evaluate(self.video(), store), ("hide", "too short"))
        self.assertEqual(filtering.evaluate(self.video(duration=1000), store), ("unknown", "needs likes"))
        self.assertEqual(filtering.evaluate(self.video(duration=1000, likes=5000), store)[0], "show")
        keys = [k for k, _ in filtering.active_filter_descriptions(store)]
        self.assertEqual(keys, ["minLikes", "minDuration"])
        filtering.remove_filter(store, "minLikes")
        self.assertEqual(store.filters["minLikes"], -1)
        store.set("search.sortMode", 1)
        filtering.clear_filters(store)
        self.assertFalse(filtering.has_active_filters(store))
        self.assertEqual(store.get("search.sortMode"), 1)  # sort survives Clear All

    def test_recency_sort(self):
        store = fresh_store()
        items = [self.video(id="a" * 11, age=500), self.video(id="b" * 11, age=-1), self.video(id="c" * 11, age=100)]
        self.assertEqual([i.id[0] for i in filtering.sort_items(items, store)], ["a", "b", "c"])
        store.set("search.sortMode", 1)
        self.assertEqual([i.id[0] for i in filtering.sort_items(items, store)], ["c", "a", "b"])


class ServicesTests(unittest.TestCase):
    def test_dearrow_rules(self):
        data = {"titles": [{"title": ">iPhone 16   review", "votes": 0, "locked": False, "original": False}],
                "thumbnails": [{"timestamp": None, "original": True, "votes": 9}]}
        self.assertEqual(services.parse_branding(data), {"title": "iPhone 16 review", "time": None})
        untrusted = {"titles": [{"title": "Clickbait", "votes": -2, "locked": False}], "thumbnails": []}
        self.assertEqual(services.parse_branding(untrusted)["title"], None)


class TakeoutTests(unittest.TestCase):
    def test_csv_and_search(self):
        csv_text = ('﻿Comment ID,Channel ID,Comment Create Timestamp,Price,Parent Comment ID,Post ID,Video ID,Comment Text\n'
                    'c1,UCx,2024-05-01T10:00:00.000+00:00,,,,dQw4w9WgXcQ,"{""text"":""Great SwiftUI tips""}"\n'
                    'c2,UCx,2023-01-01T10:00:00+00:00,,,POST,,"{""text"":""a community post""}"\n')
        records = takeout.parse_csv(csv_text)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["t"], "Great SwiftUI tips")
        store = fresh_store()
        path = os.path.join(_TMP, "comments.csv")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(csv_text)
        self.assertEqual(takeout.import_file(store, path), 1)
        self.assertEqual(takeout.import_file(store, path), 0)  # no duplicates
        self.assertEqual(len(takeout.search(store, "swiftui")), 1)
        self.assertEqual(len(takeout.search(store, "swfitui")), 0)
        store.set("search.looseNames", True)
        self.assertEqual(len(takeout.search(store, "swfitui")), 1)


class StoreTests(unittest.TestCase):
    def test_persistence(self):
        directory = tempfile.mkdtemp(dir=_TMP)
        store = Store(config_dir=directory)
        store.set("search.flexibleDates", True)
        store.subscribe("UCuAXFkgsw1L7xaCfnd5JJOw", "Dev", "devchannel")
        store.ban("spammer", "UC_x5XG1OV2P6uZZ5FSM9Ttw", "Spam")
        again = Store(config_dir=directory)
        self.assertTrue(again.get("search.flexibleDates"))
        self.assertTrue(again.is_subscribed("UCuAXFkgsw1L7xaCfnd5JJOw"))
        self.assertEqual(again.bans[0]["name"], "Spam")


class DownloadQueueTests(unittest.TestCase):
    def test_recovery_and_controls(self):
        from maxtubeplus_desktop import downloads
        store = fresh_store()
        store.set("downloads.maxConcurrent", 1)
        manager = downloads.DownloadManager(store)
        manager.pump = lambda: None  # don't start network transfers in tests
        item = manager.enqueue("dQw4w9WgXcQ", "Test")
        self.assertEqual(item["state"], downloads.QUEUED)
        manager.pause(item)
        self.assertEqual(item["state"], downloads.PAUSED)
        manager.resume(item)
        self.assertEqual(item["state"], downloads.QUEUED)
        item["state"] = downloads.DOWNLOADING
        manager._persist()
        recovered = downloads.DownloadManager(store)  # simulated restart
        self.assertEqual(recovered.recovered, 1)
        self.assertEqual(recovered.items[0]["state"], downloads.QUEUED)
        self.assertEqual(downloads.describe({"state": "paused", "progress": 0.5}), "Paused at 50%")


if __name__ == "__main__":
    unittest.main(verbosity=2)
