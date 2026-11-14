#!/usr/bin/env python3
"""Offline tests for scripts/fetch_ipa.py (link parsing, iCloud response handling)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import fetch_ipa  # noqa: E402


def icloud_payload(**overrides):
    result = {
        "anonymousPublicAccess": True,
        "requireAppleLogin": False,
        "share": {"fields": {"cloudkit.title": {"value": "MaxTube_21.45.4_6.0"}}},
        "rootRecord": {"recordType": "content", "fields": {
            "extension": {"value": "ipa"},
            "size": {"value": 123},
            "fileContent": {"value": {"size": "123", "downloadURL": "https://cvws.icloud-content.com/B/abc/${f}?o=1"}},
        }},
    }
    result.update(overrides)
    return {"results": [result]}


class FetchTests(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(fetch_ipa.classify("https://drive.icloud.com/shared/0ccuT15griiWH18iopkkRdnEQ"), ("icloud", "0ccuT15griiWH18iopkkRdnEQ"))
        self.assertEqual(fetch_ipa.classify("https://www.icloud.com/iclouddrive/0ccuT15griiWH18iopkkRdnEQ#MaxTube"), ("icloud", "0ccuT15griiWH18iopkkRdnEQ"))
        self.assertEqual(fetch_ipa.classify("https://drive.google.com/file/d/1AbCdEfGhIjKlMn/view?usp=sharing"), ("gdrive", "1AbCdEfGhIjKlMn"))
        self.assertEqual(fetch_ipa.classify("https://drive.google.com/open?id=1AbCdEfGhIjKlMn"), ("gdrive", "1AbCdEfGhIjKlMn"))
        kind, url = fetch_ipa.classify("https://www.dropbox.com/scl/fi/xyz/MaxTube.ipa?rlkey=k&dl=0")
        self.assertEqual(kind, "direct")
        self.assertIn("dl=1", url)
        self.assertEqual(fetch_ipa.classify("https://example.com/a.ipa"), ("direct", "https://example.com/a.ipa"))
        with self.assertRaises(fetch_ipa.FetchError):
            fetch_ipa.classify("ftp://example.com/a.ipa")
        with self.assertRaises(fetch_ipa.FetchError):
            fetch_ipa.classify("https://www.icloud.com/photos/")

    def test_parse_icloud(self):
        url, name, size = fetch_ipa.parse_icloud_resolve(icloud_payload())
        self.assertEqual(name, "MaxTube_21.45.4_6.0.ipa")
        self.assertEqual(size, 123)
        self.assertEqual(url, "https://cvws.icloud-content.com/B/abc/MaxTube_21.45.4_6.0.ipa?o=1")

    def test_parse_icloud_errors(self):
        with self.assertRaisesRegex(fetch_ipa.FetchError, "Anyone with the link"):
            fetch_ipa.parse_icloud_resolve(icloud_payload(requireAppleLogin=True))
        with self.assertRaisesRegex(fetch_ipa.FetchError, "folder"):
            fetch_ipa.parse_icloud_resolve(icloud_payload(rootRecord={"recordType": "folder", "fields": {}}))
        with self.assertRaises(fetch_ipa.FetchError):
            fetch_ipa.parse_icloud_resolve({"results": []})


if __name__ == "__main__":
    unittest.main(verbosity=2)
