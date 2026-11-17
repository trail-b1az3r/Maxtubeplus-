"""Google Takeout comment import + search (port of MTPCommentHistory.m).

YouTube exposes no comment-history API, and watch history misses videos you
commented on without watching, so the Takeout export is the complete source.
Parsed locally; nothing is uploaded.
"""
import csv
import html
import io
import json
import re
from datetime import datetime

from . import core


def _text_from_runs(raw):
    raw = (raw or "").strip()
    if not raw.startswith("{"):
        return raw
    try:
        runs = json.loads(f"[{raw}]")
        text = "".join(run.get("text", "") for run in runs if isinstance(run, dict))
        return text or raw
    except ValueError:
        return raw


def _date(value):
    value = (value or "").strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S %Z"):
        try:
            return int(datetime.strptime(value.replace("Z", "+0000"), fmt).timestamp())
        except ValueError:
            continue
    return None


def parse_csv(text):
    rows = list(csv.reader(io.StringIO(text.lstrip("﻿"))))
    if len(rows) < 2:
        return []
    header = [h.strip().lower() for h in rows[0]]

    def col(*names):
        return next((header.index(n) for n in names if n in header), -1)

    video_col, text_col = col("video id", "video_id"), col("comment text", "comment_text", "text")
    date_col, id_col = col("comment create timestamp", "timestamp", "created"), col("comment id", "comment_id")
    if video_col < 0 or text_col < 0:
        return []
    records = []
    for row in rows[1:]:
        if len(row) <= max(video_col, text_col):
            continue
        video_id = row[video_col].strip()
        if not core.is_video_id(video_id):
            continue  # community posts etc.
        records.append({
            "v": video_id,
            "t": _text_from_runs(row[text_col]),
            "d": _date(row[date_col]) if 0 <= date_col < len(row) else None,
            "c": row[id_col] if 0 <= id_col < len(row) and row[id_col] else None,
        })
    return records


_HTML_ENTRY = re.compile(r'watch\?v=([A-Za-z0-9_-]{11})(?:&amp;|&)lc=([A-Za-z0-9_.-]+)[^>]*>.*?</a>.*?<br\s*/?>(.*?)(?=<br|</div>|</li>|$)',
                         re.S | re.I)


def parse_html(text):
    records = []
    for video_id, comment_id, raw in _HTML_ENTRY.findall(text):
        clean = html.unescape(re.sub(r"<[^>]+>", "", raw)).strip()
        records.append({"v": video_id, "t": clean, "d": None, "c": comment_id})
    return records


def import_file(store, path):
    """Returns number of new comments. Raises ValueError with a readable message."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        content = handle.read()
    parsed = parse_html(content) if "<html" in content[:2000].lower() else parse_csv(content)
    if not parsed:
        raise ValueError('No YouTube video comments found. Choose comments.csv (or my-comments.html) from the Takeout "YouTube and YouTube Music" export.')
    existing = {r.get("c") or r["v"] + r["t"] for r in store.comments["records"]}
    added = 0
    for record in parsed:
        key = record.get("c") or record["v"] + record["t"]
        if key in existing:
            continue
        existing.add(key)
        store.comments["records"].append(record)
        added += 1
    store.comments["lastImport"] = int(datetime.now().timestamp())
    store.save("comments")
    return added


def search(store, query, sort_recent=True, titles=None):
    """Case-insensitive (typo-tolerant with loose names) over comment text and
    known video titles/channels. titles: {video_id: "title\\nchannel"}."""
    titles = titles or {}
    loose = bool(store.get("search.looseNames"))
    terms = [t for t in (query or "").lower().split() if t]
    matches = []
    for record in store.comments["records"]:
        if not terms:
            matches.append((0, record))
            continue
        haystack = f"{record['t']}\n{titles.get(record['v'], '')}"
        score = 0
        for term in terms:
            if not core.contains(haystack, term, loose):
                break
            score += 3 if core.contains(record["t"], term, loose) else 1
        else:
            matches.append((score, record))
    if sort_recent or not terms:
        matches.sort(key=lambda m: -(m[1].get("d") or 0))
    else:
        matches.sort(key=lambda m: (-m[0], -(m[1].get("d") or 0)))
    return [record for _, record in matches]
