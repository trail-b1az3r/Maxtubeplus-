"""ctypes bridge to MaxTubePlus's portable C core (MaxTubePlus/Core/MTPCore.c).

The iOS tweak and this desktop app run the same filter, matching, parsing and
search-parameter code, so a filter or ban behaves identically on both.
"""
import base64
import ctypes
import os
from dataclasses import dataclass

_SEARCH_PATHS = [
    os.environ.get("MTP_CORE_LIB", ""),
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "libmtpcore.so"),
    "/usr/lib/maxtubeplus/libmtpcore.so",
]


def _load():
    for path in _SEARCH_PATHS:
        if path and os.path.exists(path):
            return ctypes.CDLL(path)
    raise OSError("libmtpcore.so not found. Build it with `make core` in linux/ (or install the package).")


_lib = _load()


class SearchFilter(ctypes.Structure):
    _fields_ = [
        ("minLikes", ctypes.c_longlong),
        ("minDurationSeconds", ctypes.c_long),
        ("maxDurationSeconds", ctypes.c_long),
        ("maxAgeSeconds", ctypes.c_longlong),
        ("uploadedAfterUnix", ctypes.c_longlong),
        ("uploadedBeforeUnix", ctypes.c_longlong),
        ("flexibleDates", ctypes.c_bool),
    ]


class VideoFacts(ctypes.Structure):
    _fields_ = [
        ("durationSeconds", ctypes.c_long),
        ("likes", ctypes.c_longlong),
        ("ageSeconds", ctypes.c_longlong),
    ]


# Mirrors MTPFilterResult
PASS, REJECT_LIKES, REJECT_SHORT, REJECT_LONG, REJECT_AGE, REJECT_WINDOW, UNKNOWN = range(7)

_B = ctypes.c_char_p
_lib.mtp_parse_duration.argtypes = [_B]; _lib.mtp_parse_duration.restype = ctypes.c_long
_lib.mtp_parse_count.argtypes = [_B]; _lib.mtp_parse_count.restype = ctypes.c_longlong
_lib.mtp_parse_relative_age.argtypes = [_B]; _lib.mtp_parse_relative_age.restype = ctypes.c_longlong
_lib.mtp_filter_reset.argtypes = [ctypes.POINTER(SearchFilter)]
_lib.mtp_filter_active_count.argtypes = [ctypes.POINTER(SearchFilter)]; _lib.mtp_filter_active_count.restype = ctypes.c_int
_lib.mtp_filter_evaluate.argtypes = [ctypes.POINTER(SearchFilter), ctypes.POINTER(VideoFacts), ctypes.c_longlong]
_lib.mtp_filter_evaluate.restype = ctypes.c_int
_lib.mtp_ci_contains.argtypes = [_B, ctypes.c_size_t, _B, ctypes.c_size_t]; _lib.mtp_ci_contains.restype = ctypes.c_bool
_lib.mtp_ci_contains_token.argtypes = [_B, ctypes.c_size_t, _B, ctypes.c_size_t]; _lib.mtp_ci_contains_token.restype = ctypes.c_bool
_lib.mtp_fuzzy_contains.argtypes = [_B, ctypes.c_size_t, _B, ctypes.c_size_t, ctypes.c_int]; _lib.mtp_fuzzy_contains.restype = ctypes.c_bool
_lib.mtp_fuzzy_budget.argtypes = [ctypes.c_size_t]; _lib.mtp_fuzzy_budget.restype = ctypes.c_int
_lib.mtp_upload_code_for_age.argtypes = [ctypes.c_longlong]; _lib.mtp_upload_code_for_age.restype = ctypes.c_int
_lib.mtp_duration_code_for_range.argtypes = [ctypes.c_long, ctypes.c_long]; _lib.mtp_duration_code_for_range.restype = ctypes.c_int
_lib.mtp_search_params_encode.argtypes = [ctypes.c_bool, ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t]
_lib.mtp_search_params_encode.restype = ctypes.c_size_t
_lib.mtp_retry_delay.argtypes = [ctypes.c_int, ctypes.c_double, ctypes.c_double]; _lib.mtp_retry_delay.restype = ctypes.c_double
_lib.mtp_is_video_id.argtypes = [_B]; _lib.mtp_is_video_id.restype = ctypes.c_bool


def _b(text):
    return text.encode("utf-8") if isinstance(text, str) else (text or b"")


def parse_duration(text):
    return _lib.mtp_parse_duration(_b(text)) if text else -1


def parse_count(text):
    return _lib.mtp_parse_count(_b(text)) if text else -1


def parse_relative_age(text):
    return _lib.mtp_parse_relative_age(_b(text)) if text else -1


def is_video_id(text):
    return bool(text) and _lib.mtp_is_video_id(_b(text))


def contains(haystack, needle, loose=False):
    """Case-insensitive; with loose=True also tolerates small typos (same budget as iOS)."""
    h, n = _b(haystack), _b(needle)
    if not n:
        return False
    edits = _lib.mtp_fuzzy_budget(len(n)) if loose else 0
    return _lib.mtp_fuzzy_contains(h, len(h), n, len(n), edits)


def contains_token(haystack, needle):
    """Whole-token, case-insensitive match (for #tags and @handles)."""
    h, n = _b(haystack), _b(needle)
    return bool(n) and _lib.mtp_ci_contains_token(h, len(h), n, len(n))


def retry_delay(attempt, base=5.0, cap=300.0):
    return _lib.mtp_retry_delay(attempt, base, cap)


@dataclass
class Filters:
    min_likes: int = -1
    min_duration: int = -1      # seconds
    max_duration: int = -1      # seconds
    max_age: int = -1           # seconds ("recency")
    uploaded_after: int = -1    # unix
    uploaded_before: int = -1   # unix
    flexible_dates: bool = False

    def to_c(self):
        f = SearchFilter()
        _lib.mtp_filter_reset(ctypes.byref(f))
        f.minLikes, f.minDurationSeconds, f.maxDurationSeconds = self.min_likes, self.min_duration, self.max_duration
        f.maxAgeSeconds, f.uploadedAfterUnix, f.uploadedBeforeUnix = self.max_age, self.uploaded_after, self.uploaded_before
        f.flexibleDates = self.flexible_dates
        return f

    def active_count(self):
        return _lib.mtp_filter_active_count(ctypes.byref(self.to_c()))

    def evaluate(self, duration=-1, likes=-1, age=-1, now=0):
        facts = VideoFacts(duration, likes, age)
        return _lib.mtp_filter_evaluate(ctypes.byref(self.to_c()), ctypes.byref(facts), now)


def search_params(sort_by_date, max_age=-1, min_duration=-1, max_duration=-1):
    """YouTube's search `sp` value (URL-escaped base64), or "" if nothing applies."""
    upload = _lib.mtp_upload_code_for_age(max_age)
    duration = _lib.mtp_duration_code_for_range(min_duration, max_duration)
    buffer = ctypes.create_string_buffer(16)
    length = _lib.mtp_search_params_encode(bool(sort_by_date), upload, duration, buffer, 16)
    if not length:
        return ""
    return base64.b64encode(buffer.raw[:length]).decode().replace("=", "%3D")
