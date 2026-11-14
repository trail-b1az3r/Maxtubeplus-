#!/usr/bin/env python3
"""Download an IPA from a direct URL or a cloud share link.

Supported links
  iCloud Drive   https://www.icloud.com/iclouddrive/<id>[#name]
                 https://drive.icloud.com/shared/<id>   (and icloud.com/... variants)
  Google Drive   https://drive.google.com/file/d/<id>/view, ...?id=<id>
  Dropbox        https://www.dropbox.com/s|scl/fi/...    (dl=0 -> dl=1)
  anything else  downloaded as-is (must be a direct link to the file)

iCloud links are resolved through the same public CloudKit "resolve" call the
iCloud website uses for shared files. The share must be set to "Anyone with
the link"; links restricted to invited people need an Apple ID sign-in and
cannot be downloaded by a workflow.

Usage: fetch_ipa.py URL OUTPUT [--retries N]
Prints only the file name and size (never the share owner or signed URLs);
under GitHub Actions resolved download URLs are masked in the log.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ICLOUD_RESOLVE = "https://ckdatabasews.icloud.com/database/1/com.apple.cloudkit/production/public/records/resolve"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
ZIP_MAGIC = b"PK\x03\x04"


class FetchError(Exception):
    pass


def mask(value):
    if os.environ.get("GITHUB_ACTIONS") and value:
        print(f"::add-mask::{value}")


def classify(url):
    """Returns (kind, id_or_url)."""
    parsed = urllib.parse.urlparse(url.strip())
    host = (parsed.hostname or "").lower()
    path = parsed.path
    if parsed.scheme not in ("http", "https") or not host:
        raise FetchError("The IPA URL must start with http:// or https://")
    if host.endswith("icloud.com") or host.endswith("icloud.com.cn"):
        match = re.search(r"/(?:iclouddrive|shared)/([0-9A-Za-z_-]{10,})", path)
        if not match:
            raise FetchError("Unrecognised iCloud link. Use the link from Share › Copy Link (…/iclouddrive/<id> or drive.icloud.com/shared/<id>).")
        return "icloud", match.group(1)
    if host in ("drive.google.com", "docs.google.com", "drive.usercontent.google.com"):
        match = re.search(r"/d/([0-9A-Za-z_-]{10,})", path)
        query_id = urllib.parse.parse_qs(parsed.query).get("id", [None])[0]
        file_id = match.group(1) if match else query_id
        if not file_id:
            raise FetchError("Unrecognised Google Drive link.")
        return "gdrive", file_id
    if host.endswith("dropbox.com"):
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        query["dl"] = ["1"]
        return "direct", urllib.parse.urlunparse(parsed._replace(query=urllib.parse.urlencode(query, doseq=True)))
    return "direct", url.strip()


def parse_icloud_resolve(payload):
    """Extracts (download_url, filename, size) from a CloudKit resolve response."""
    results = payload.get("results") or []
    if not results:
        raise FetchError("iCloud did not return the shared file (link deleted or mistyped?).")
    result = results[0]
    if result.get("reason") or result.get("serverErrorCode"):
        raise FetchError(f"iCloud refused the link: {result.get('reason') or result.get('serverErrorCode')}.")
    if result.get("requireAppleLogin") or result.get("anonymousPublicAccess") is False:
        raise FetchError("This iCloud link only works for invited people. In the Files app: Share › Share Options › Who can access: Anyone with the link, then copy the link again.")
    record = result.get("rootRecord") or {}
    fields = record.get("fields") or {}
    content = (fields.get("fileContent") or {}).get("value") or {}
    url = content.get("downloadURL")
    if not url:
        if record.get("recordType") in ("folder", "app_library"):
            raise FetchError("This iCloud link is a folder. Share the .ipa file itself.")
        raise FetchError("iCloud returned no download URL for this share.")
    name = (fields.get("cloudkit.title") or {}).get("value") or ((result.get("share") or {}).get("fields") or {}).get("cloudkit.title", {}).get("value")
    if not name:
        import base64
        encoded = (fields.get("encryptedBasename") or {}).get("value")
        try:
            name = base64.b64decode(encoded).decode("utf-8") if encoded else None
        except Exception:
            name = None
    extension = (fields.get("extension") or {}).get("value") or "ipa"
    name = name or "download"
    if not name.lower().endswith("." + extension.lower()):
        name = f"{name}.{extension}"
    size = int(content.get("size") or (fields.get("size") or {}).get("value") or 0)
    return url.replace("${f}", urllib.parse.quote(name)), name, size


def resolve_icloud(share_id):
    body = json.dumps({"shortGUIDs": [{"value": share_id}]}).encode()
    request = urllib.request.Request(ICLOUD_RESOLVE, data=body, method="POST", headers={
        "Content-Type": "text/plain", "Origin": "https://www.icloud.com", "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise FetchError(f"iCloud lookup failed (HTTP {error.code}).")
    except (urllib.error.URLError, json.JSONDecodeError) as error:
        raise FetchError(f"iCloud lookup failed ({error}).")
    return parse_icloud_resolve(payload)


def download(url, output, expected_size=0, retries=3):
    for attempt in range(1, retries + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=60) as response, open(output, "wb") as handle:
                total = expected_size or int(response.headers.get("Content-Length") or 0)
                received, last_report = 0, 0
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    handle.write(chunk)
                    received += len(chunk)
                    if received - last_report >= 25 << 20:
                        last_report = received
                        print(f"  {received >> 20} MB" + (f" / {total >> 20} MB" if total else ""), flush=True)
            if expected_size and received != expected_size:
                raise FetchError(f"incomplete download ({received} of {expected_size} bytes)")
            return received
        except (urllib.error.URLError, OSError, FetchError) as error:
            if attempt == retries:
                raise FetchError(f"Download failed after {retries} attempts: {error}")
            wait = 2 ** attempt
            print(f"Download attempt {attempt} failed ({error}); retrying in {wait}s", flush=True)
            time.sleep(wait)
    return 0


def gdrive_url(file_id):
    return f"https://drive.usercontent.google.com/download?id={file_id}&export=download&confirm=t"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("url")
    parser.add_argument("output")
    parser.add_argument("--retries", type=int, default=3)
    args = parser.parse_args()
    mask(args.url)
    try:
        kind, value = classify(args.url)
        size = 0
        if kind == "icloud":
            url, name, size = resolve_icloud(value)
            print(f"iCloud Drive file: {name} ({size / 1048576:.1f} MB)")
        elif kind == "gdrive":
            url = gdrive_url(value)
            print("Google Drive file")
        else:
            url = value
        mask(url)
        received = download(url, args.output, size, args.retries)
        with open(args.output, "rb") as handle:
            magic = handle.read(4)
        if magic != ZIP_MAGIC:
            hint = " (Google Drive may require the file to be shared with 'Anyone with the link')" if kind == "gdrive" else ""
            raise FetchError(f"The downloaded file is not an IPA/zip{hint}. Check that the link points to the .ipa file itself.")
        print(f"Downloaded {received / 1048576:.1f} MB to {args.output}")
    except FetchError as error:
        print(f"::error::{error}")
        sys.exit(1)


if __name__ == "__main__":
    main()
