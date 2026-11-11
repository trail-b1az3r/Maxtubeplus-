#include "MTPCore.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

static long next_component(const char **cursor) {
    const char *p = *cursor;
    if (!p || !*p) return 0;
    long value = 0;
    while (*p && isdigit((unsigned char)*p)) {
        value = value * 10 + (*p - '0');
        p++;
    }
    while (*p && !isdigit((unsigned char)*p)) p++;
    *cursor = p;
    return value;
}

int mtp_version_compare(const char *a, const char *b) {
    const char *pa = a ? a : "";
    const char *pb = b ? b : "";
    for (int i = 0; i < 8; i++) {
        if (!*pa && !*pb) return 0;
        long va = next_component(&pa);
        long vb = next_component(&pb);
        if (va != vb) return va < vb ? -1 : 1;
    }
    return 0;
}

static long major_of(const char *v) {
    const char *p = v ? v : "";
    return next_component(&p);
}

MTPCompatLevel mtp_compat_level(const char *appVersion, const char *target, const char *minimum) {
    if (!appVersion || !*appVersion || !isdigit((unsigned char)appVersion[0])) return MTPCompatUnknown;
    if (mtp_version_compare(appVersion, target) == 0) return MTPCompatVerified;
    if (minimum && mtp_version_compare(appVersion, minimum) < 0) return MTPCompatUnsupported;
    if (major_of(appVersion) != major_of(target)) return MTPCompatUnsupported;
    return MTPCompatSameMajor;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

long mtp_parse_duration(const char *text) {
    if (!text) return -1;
    const char *p = text;
    while (*p && !isdigit((unsigned char)*p)) p++;
    if (!*p) return -1;
    long parts[3] = {0, 0, 0};
    int count = 0;
    while (*p && count < 3) {
        if (!isdigit((unsigned char)*p)) return -1;
        long v = 0;
        int digits = 0;
        while (isdigit((unsigned char)*p)) {
            v = v * 10 + (*p - '0');
            p++;
            digits++;
            if (digits > 6) return -1;
        }
        parts[count++] = v;
        if (*p == ':') {
            p++;
            continue;
        }
        break;
    }
    // Remaining characters must be whitespace.
    while (*p) {
        if (!isspace((unsigned char)*p)) return -1;
        p++;
    }
    if (count < 2) return -1;
    // Validate minute/second ranges for components after the first.
    for (int i = 1; i < count; i++) if (parts[i] > 59) return -1;
    if (count == 2) return parts[0] * 60 + parts[1];
    return parts[0] * 3600 + parts[1] * 60 + parts[2];
}

long long mtp_parse_count(const char *text) {
    if (!text) return -1;
    const char *p = text;
    while (*p && !isdigit((unsigned char)*p)) p++;
    if (!*p) return -1;
    long long whole = 0;
    long long frac = 0;
    long long fracScale = 1;
    bool inFrac = false;
    for (; *p; p++) {
        if (isdigit((unsigned char)*p)) {
            if (inFrac) {
                if (fracScale < 1000000) {
                    frac = frac * 10 + (*p - '0');
                    fracScale *= 10;
                }
            } else {
                whole = whole * 10 + (*p - '0');
            }
        } else if (*p == ',' && !inFrac && isdigit((unsigned char)p[1])) {
            continue; // thousands separator
        } else if (*p == '.' && !inFrac && isdigit((unsigned char)p[1])) {
            inFrac = true;
        } else {
            break;
        }
    }
    while (*p == ' ') p++;
    long long multiplier = 1;
    switch (*p) {
        case 'K': case 'k': multiplier = 1000LL; break;
        case 'M': case 'm':
            // "M" as in million, but avoid "minutes".
            if (!isalpha((unsigned char)p[1]) || strncmp(p, "million", 7) == 0 || strncmp(p, "M ", 2) == 0) multiplier = 1000000LL;
            break;
        case 'B': case 'b':
            if (!isalpha((unsigned char)p[1]) || strncmp(p, "billion", 7) == 0) multiplier = 1000000000LL;
            break;
        default: break;
    }
    return whole * multiplier + (frac * multiplier) / fracScale;
}

typedef struct { const char *word; long long seconds; } unit_t;

long long mtp_parse_relative_age(const char *text) {
    if (!text) return -1;
    static const unit_t units[] = {
        {"second", 1}, {"minute", 60}, {"hour", 3600}, {"day", 86400},
        {"week", 604800}, {"month", 2629800}, {"year", 31557600},
    };
    const char *p = text;
    while (*p && !isdigit((unsigned char)*p)) p++;
    if (!*p) return -1;
    long long n = 0;
    while (isdigit((unsigned char)*p)) n = n * 10 + (*p++ - '0');
    while (*p == ' ') p++;
    for (size_t i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
        size_t len = strlen(units[i].word);
        if (strncasecmp(p, units[i].word, len) == 0) return n * units[i].seconds;
    }
    return -1;
}

static bool is_id_char(char c) {
    return isalnum((unsigned char)c) || c == '-' || c == '_';
}

bool mtp_is_channel_id(const char *text, size_t length) {
    if (!text || length != 24) return false;
    if (text[0] != 'U' || text[1] != 'C') return false;
    for (size_t i = 2; i < 24; i++) if (!is_id_char(text[i])) return false;
    return true;
}

size_t mtp_scan_channel_ids(const char *haystack, size_t length,
                            void (*callback)(const char *channelID, void *context),
                            void *context) {
    if (!haystack) return 0;
    size_t found = 0;
    for (size_t i = 0; i + 24 <= length; i++) {
        if (haystack[i] != 'U' || haystack[i + 1] != 'C') continue;
        if (i > 0 && is_id_char(haystack[i - 1])) continue;
        if (i + 24 < length && is_id_char(haystack[i + 24])) continue;
        if (!mtp_is_channel_id(haystack + i, 24)) continue;
        char buffer[25];
        memcpy(buffer, haystack + i, 24);
        buffer[24] = '\0';
        if (callback) callback(buffer, context);
        found++;
        i += 23;
    }
    return found;
}

bool mtp_is_video_id(const char *text) {
    if (!text || strlen(text) != 11) return false;
    for (int i = 0; i < 11; i++) if (!is_id_char(text[i])) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

void mtp_filter_reset(MTPSearchFilter *f) {
    if (!f) return;
    f->minLikes = -1;
    f->minDurationSeconds = -1;
    f->maxDurationSeconds = -1;
    f->maxAgeSeconds = -1;
    f->uploadedAfterUnix = -1;
    f->uploadedBeforeUnix = -1;
}

int mtp_filter_active_count(const MTPSearchFilter *f) {
    if (!f) return 0;
    int n = 0;
    if (f->minLikes >= 0) n++;
    if (f->minDurationSeconds >= 0) n++;
    if (f->maxDurationSeconds >= 0) n++;
    if (f->maxAgeSeconds >= 0) n++;
    if (f->uploadedAfterUnix >= 0 || f->uploadedBeforeUnix >= 0) n++;
    return n;
}

bool mtp_filter_is_active(const MTPSearchFilter *f) {
    return mtp_filter_active_count(f) > 0;
}

MTPFilterResult mtp_filter_evaluate(const MTPSearchFilter *f, const MTPVideoFacts *v, long long now) {
    if (!f || !v) return MTPFilterPass;
    bool unknown = false;
    if (f->minDurationSeconds >= 0 || f->maxDurationSeconds >= 0) {
        if (v->durationSeconds < 0) unknown = true;
        else {
            if (f->minDurationSeconds >= 0 && v->durationSeconds < f->minDurationSeconds) return MTPFilterRejectDurationShort;
            if (f->maxDurationSeconds >= 0 && v->durationSeconds > f->maxDurationSeconds) return MTPFilterRejectDurationLong;
        }
    }
    if (f->maxAgeSeconds >= 0) {
        if (v->ageSeconds < 0) unknown = true;
        else if (v->ageSeconds > f->maxAgeSeconds) return MTPFilterRejectAge;
    }
    if (f->uploadedAfterUnix >= 0 || f->uploadedBeforeUnix >= 0) {
        if (v->ageSeconds < 0) unknown = true;
        else {
            long long uploaded = now - v->ageSeconds;
            if (f->uploadedAfterUnix >= 0 && uploaded < f->uploadedAfterUnix) return MTPFilterRejectUploadWindow;
            if (f->uploadedBeforeUnix >= 0 && uploaded > f->uploadedBeforeUnix) return MTPFilterRejectUploadWindow;
        }
    }
    if (f->minLikes >= 0) {
        if (v->likes < 0) unknown = true;
        else if (v->likes < f->minLikes) return MTPFilterRejectLikes;
    }
    return unknown ? MTPFilterUnknown : MTPFilterPass;
}

static MTPSortMode g_sort_mode;

static int compare_keys(const void *a, const void *b) {
    const MTPSortKey *x = a, *y = b;
    if (g_sort_mode == MTPSortRecency) {
        bool xu = x->ageSeconds < 0, yu = y->ageSeconds < 0;
        if (xu != yu) return xu ? 1 : -1;
        if (!xu && x->ageSeconds != y->ageSeconds) return x->ageSeconds < y->ageSeconds ? -1 : 1;
    }
    if (x->originalIndex == y->originalIndex) return 0;
    return x->originalIndex < y->originalIndex ? -1 : 1;
}

void mtp_sort_keys(MTPSortKey *keys, size_t count, MTPSortMode mode) {
    if (!keys || count < 2) return;
    // originalIndex is a total tiebreaker, so qsort's instability is harmless.
    g_sort_mode = mode;
    qsort(keys, count, sizeof(MTPSortKey), compare_keys);
}

// ---------------------------------------------------------------------------
// Suppression
// ---------------------------------------------------------------------------

int mtp_clamp_threshold(int threshold) {
    if (threshold < 2) return 2;
    if (threshold > 20) return 20;
    return threshold;
}

bool mtp_record_negative_feedback(MTPCreatorRecord *r, const MTPSuppressionPolicy *policy, long long now) {
    if (!r || !policy) return false;
    if (r->suppressed) {
        r->lastEventUnix = now;
        return false;
    }
    if (policy->windowSeconds > 0 && r->negativeCount > 0 && now - r->lastEventUnix > policy->windowSeconds) {
        // Streak decayed.
        r->negativeCount = 0;
    }
    if (r->negativeCount == 0) r->firstEventUnix = now;
    r->negativeCount++;
    r->lastEventUnix = now;
    if (!policy->autoSuppress) return false;
    if (r->negativeCount >= mtp_clamp_threshold(policy->threshold)) {
        r->suppressed = true;
        r->restoredByUser = false;
        return true;
    }
    return false;
}

void mtp_restore_creator(MTPCreatorRecord *r) {
    if (!r) return;
    r->suppressed = false;
    r->negativeCount = 0;
    r->restoredByUser = true;
}

bool mtp_surface_allows_suppression(MTPSurface s) {
    switch (s) {
        case MTPSurfaceHome:
        case MTPSurfaceShorts:
        case MTPSurfaceWatchNext:
        case MTPSurfaceExplore:
            return true;
        case MTPSurfaceSubscriptions:   // the user subscribed explicitly
        case MTPSurfaceSearch:
        case MTPSurfaceChannelSearch:
        case MTPSurfaceChannelPage:
        case MTPSurfaceOther:
        default:
            return false;
    }
}

// ---------------------------------------------------------------------------
// DeArrow
// ---------------------------------------------------------------------------

size_t mtp_dearrow_clean_title(char *title) {
    if (!title) return 0;
    char *src = title, *dst = title;
    bool lastSpace = true; // trims leading whitespace
    while (*src) {
        char c = *src++;
        // DeArrow marks words that must keep their original casing with a
        // leading '>' (e.g. ">iPhone"). Remove the marker at word starts.
        if (c == '>' && lastSpace && *src && !isspace((unsigned char)*src)) continue;
        if (isspace((unsigned char)c)) {
            if (lastSpace) continue;
            *dst++ = ' ';
            lastSpace = true;
            continue;
        }
        *dst++ = c;
        lastSpace = false;
    }
    if (dst > title && dst[-1] == ' ') dst--;
    *dst = '\0';
    return (size_t)(dst - title);
}

uint32_t mtp_fnv1a(const char *text) {
    uint32_t hash = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)(text ? text : ""); *p; p++) {
        hash ^= *p;
        hash *= 16777619u;
    }
    return hash;
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

void mtp_tabs_init(MTPTabList *l) {
    if (l) memset(l, 0, sizeof(*l));
}

long mtp_tabs_index_of(const MTPTabList *l, const char *id) {
    if (!l || !id) return -1;
    for (size_t i = 0; i < l->count; i++) if (strcmp(l->identifiers[i], id) == 0) return (long)i;
    return -1;
}

bool mtp_tabs_append(MTPTabList *l, const char *id) {
    if (!l || !id || !*id || l->count >= MTP_MAX_TABS || strlen(id) >= MTP_TAB_ID_LEN) return false;
    if (mtp_tabs_index_of(l, id) >= 0) return false;
    strcpy(l->identifiers[l->count++], id);
    return true;
}

bool mtp_tabs_remove(MTPTabList *l, const char *id) {
    long idx = mtp_tabs_index_of(l, id);
    if (idx < 0) return false;
    memmove(l->identifiers[idx], l->identifiers[idx + 1], (l->count - (size_t)idx - 1) * MTP_TAB_ID_LEN);
    l->count--;
    return true;
}

void mtp_tabs_arrange(const MTPTabList *present, const MTPTabList *order,
                      const MTPTabList *hidden, const MTPTabList *injectable,
                      MTPTabList *result) {
    mtp_tabs_init(result);
    if (!present) return;
    if (order) {
        for (size_t i = 0; i < order->count; i++) {
            const char *id = order->identifiers[i];
            if (hidden && mtp_tabs_index_of(hidden, id) >= 0) continue;
            bool exists = mtp_tabs_index_of(present, id) >= 0;
            bool canInject = injectable && mtp_tabs_index_of(injectable, id) >= 0;
            if (exists || canInject) mtp_tabs_append(result, id);
        }
    }
    for (size_t i = 0; i < present->count; i++) {
        const char *id = present->identifiers[i];
        if (hidden && mtp_tabs_index_of(hidden, id) >= 0) continue;
        mtp_tabs_append(result, id);
    }
    if (result->count == 0 && present->count > 0) mtp_tabs_append(result, present->identifiers[0]);
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

double mtp_retry_delay(int attempt, double base, double cap) {
    if (attempt < 0) attempt = 0;
    double d = base;
    for (int i = 0; i < attempt && d < cap; i++) d *= 2;
    return d > cap ? cap : d;
}

long mtp_pick_format(const int *heights, const bool *isAudio, const long *bitrates,
                     size_t count, int maxHeight, bool wantAudioOnly) {
    long best = -1;
    for (size_t i = 0; i < count; i++) {
        if (wantAudioOnly) {
            if (!isAudio[i]) continue;
            if (best < 0 || bitrates[i] > bitrates[best]) best = (long)i;
        } else {
            if (isAudio[i]) continue;
            if (maxHeight > 0 && heights[i] > maxHeight) continue;
            if (best < 0 || heights[i] > heights[best] ||
                (heights[i] == heights[best] && bitrates[i] > bitrates[best])) best = (long)i;
        }
    }
    if (best < 0 && !wantAudioOnly && maxHeight > 0) {
        // Nothing at or below the cap: fall back to the smallest available.
        for (size_t i = 0; i < count; i++) {
            if (isAudio[i]) continue;
            if (best < 0 || heights[i] < heights[best]) best = (long)i;
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// Protocol buffers
// ---------------------------------------------------------------------------

size_t mtp_scan_thumbnail_video_ids(const uint8_t *bytes, size_t length,
                                    void (*callback)(const char *videoID, void *context),
                                    void *context) {
    if (!bytes) return 0;
    static const char *const prefixes[] = {"/vi/", "/vi_webp/"};
    char seen[32][12];
    size_t found = 0;
    for (size_t i = 0; i < length; i++) {
        for (size_t p = 0; p < 2; p++) {
            size_t plen = strlen(prefixes[p]);
            if (i + plen + 12 > length || memcmp(bytes + i, prefixes[p], plen) != 0) continue;
            const uint8_t *id = bytes + i + plen;
            if (id[11] != '/') continue;
            bool ok = true;
            for (int k = 0; k < 11; k++) if (!is_id_char((char)id[k])) { ok = false; break; }
            if (!ok) continue;
            char buffer[12];
            memcpy(buffer, id, 11);
            buffer[11] = '\0';
            bool duplicate = false;
            for (size_t s = 0; s < found && s < 32; s++) if (strcmp(seen[s], buffer) == 0) { duplicate = true; break; }
            if (duplicate) continue;
            if (found < 32) strcpy(seen[found], buffer);
            found++;
            if (callback) callback(buffer, context);
        }
    }
    return found;
}

bool mtp_pb_contains_string_field(const uint8_t *bytes, size_t length, const char *value, size_t valueLength) {
    if (!bytes || !value || valueLength == 0 || valueLength > 16383 || valueLength > length) return false;
    size_t prefix = valueLength < 128 ? 1 : 2;
    uint8_t lenBytes[2];
    if (prefix == 1) lenBytes[0] = (uint8_t)valueLength;
    else { lenBytes[0] = (uint8_t)((valueLength & 0x7F) | 0x80); lenBytes[1] = (uint8_t)(valueLength >> 7); }
    for (size_t i = prefix + 1; i + valueLength <= length; i++) {
        if (memcmp(bytes + i, value, valueLength) != 0) continue;
        if (memcmp(bytes + i - prefix, lenBytes, prefix) != 0) continue;
        uint8_t tag = bytes[i - prefix - 1];
        if ((tag & 0x07) == 2 && tag >= 0x0A) return true;
    }
    return false;
}

MTPUploadCode mtp_upload_code_for_age(long long a) {
    if (a < 0) return MTPUploadAny;
    if (a <= 3600) return MTPUploadHour;
    if (a <= 86400) return MTPUploadToday;
    if (a <= 7 * 86400) return MTPUploadWeek;
    if (a <= 31 * 86400) return MTPUploadMonth;
    if (a <= 366 * 86400) return MTPUploadYear;
    return MTPUploadAny;
}

MTPDurationCode mtp_duration_code_for_range(long minS, long maxS) {
    // Server buckets: short < 4 min, medium 4-20 min, long > 20 min.
    if (minS >= 1200) return MTPDurationLong;
    if (maxS >= 0 && maxS <= 240) return MTPDurationShort;
    if (minS >= 240 && maxS >= 0 && maxS <= 1200) return MTPDurationMedium;
    return MTPDurationAny;
}

size_t mtp_search_params_encode(bool sortByUploadDate, MTPUploadCode upload, MTPDurationCode duration,
                                uint8_t *out, size_t capacity) {
    uint8_t buffer[16];
    size_t n = 0;
    if (sortByUploadDate) { buffer[n++] = 0x08; buffer[n++] = 0x02; }
    uint8_t filters[8];
    size_t f = 0;
    if (upload != MTPUploadAny) { filters[f++] = 0x08; filters[f++] = (uint8_t)upload; }
    if (upload != MTPUploadAny || duration != MTPDurationAny) { filters[f++] = 0x10; filters[f++] = 0x01; } // type = video
    if (duration != MTPDurationAny) { filters[f++] = 0x18; filters[f++] = (uint8_t)duration; }
    if (f > 0) {
        buffer[n++] = 0x12;
        buffer[n++] = (uint8_t)f;
        memcpy(buffer + n, filters, f);
        n += f;
    }
    if (n == 0 || n > capacity || !out) return 0;
    memcpy(out, buffer, n);
    return n;
}
