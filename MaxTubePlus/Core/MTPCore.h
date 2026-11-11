// MaxTubePlus — portable core logic.
//
// Everything in this file is plain C99 with no Apple frameworks so that it can
// be unit-tested on any host (see Tests/core_tests.c) and reused by every
// Objective-C module. Keep UI / runtime code out of here.

#ifndef MTP_CORE_H
#define MTP_CORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

/// Compares dotted numeric versions ("21.42.4" vs "21.43"). Missing components
/// count as 0. Returns <0, 0 or >0.
int mtp_version_compare(const char *a, const char *b);

typedef enum {
    MTPCompatUnknown = 0,     // Not a YouTube build we know anything about.
    MTPCompatVerified = 1,    // Exactly the version MaxTubePlus targets.
    MTPCompatSameMajor = 2,   // Same 21.x train: hooks are attempted, each one guarded.
    MTPCompatUnsupported = 3, // Older than the minimum / different major: fail safe.
} MTPCompatLevel;

/// Classifies an app version against the target (e.g. "21.42.4") and the
/// minimum version for which the hooks were written.
MTPCompatLevel mtp_compat_level(const char *appVersion, const char *target, const char *minimum);

// ---------------------------------------------------------------------------
// Parsing of YouTube-formatted text
// ---------------------------------------------------------------------------

/// Parses "1:02:03", "12:34", "0:59" into seconds. Returns -1 when the text is
/// not a duration.
long mtp_parse_duration(const char *text);

/// Parses abbreviated counts as rendered by YouTube: "1.2K", "3M likes",
/// "12,345", "1.5B". Returns -1 when no number is found.
long long mtp_parse_count(const char *text);

/// Parses relative upload ages ("3 days ago", "1 year ago", "Streamed 2 weeks
/// ago", "5 minutes ago") into an approximate age in seconds. English only;
/// returns -1 if the string is not recognised.
long long mtp_parse_relative_age(const char *text);

/// Returns true for strings shaped like a YouTube channel ID (UC + 22 chars).
bool mtp_is_channel_id(const char *text, size_t length);

/// Scans `haystack` for every channel ID and invokes `callback` with each one
/// (NUL-terminated, 24 chars). Returns the number of IDs found.
size_t mtp_scan_channel_ids(const char *haystack, size_t length,
                            void (*callback)(const char *channelID, void *context),
                            void *context);

/// Returns true for 11-character YouTube video IDs.
bool mtp_is_video_id(const char *text);

// ---------------------------------------------------------------------------
// Advanced search filters
// ---------------------------------------------------------------------------

typedef struct {
    // Each bound is disabled when < 0.
    long long minLikes;
    long minDurationSeconds;
    long maxDurationSeconds;
    long long maxAgeSeconds;       // "Recency": only videos newer than this.
    long long uploadedAfterUnix;   // "Upload date": absolute lower bound.
    long long uploadedBeforeUnix;  // "Upload date": absolute upper bound.
} MTPSearchFilter;

typedef struct {
    long durationSeconds;   // -1 if unknown
    long long likes;        // -1 if unknown
    long long ageSeconds;   // -1 if unknown
} MTPVideoFacts;

typedef enum {
    MTPFilterPass = 0,
    MTPFilterRejectLikes,
    MTPFilterRejectDurationShort,
    MTPFilterRejectDurationLong,
    MTPFilterRejectAge,
    MTPFilterRejectUploadWindow,
    MTPFilterUnknown,       // A filter is active but the fact needed is unknown.
} MTPFilterResult;

void mtp_filter_reset(MTPSearchFilter *filter);
bool mtp_filter_is_active(const MTPSearchFilter *filter);
/// Number of individually removable active filters.
int mtp_filter_active_count(const MTPSearchFilter *filter);
/// `nowUnix` is used to translate ages into absolute upload times.
MTPFilterResult mtp_filter_evaluate(const MTPSearchFilter *filter, const MTPVideoFacts *facts, long long nowUnix);

typedef enum {
    MTPSortRelevance = 0,
    MTPSortRecency = 1,
} MTPSortMode;

typedef struct {
    size_t originalIndex;   // Position in the server-provided (relevance) order.
    long long ageSeconds;   // -1 if unknown.
} MTPSortKey;

/// Sorts keys in place. Relevance restores the server order; recency sorts by
/// ascending age with unknown ages last (stable).
void mtp_sort_keys(MTPSortKey *keys, size_t count, MTPSortMode mode);

// ---------------------------------------------------------------------------
// Creator suppression
// ---------------------------------------------------------------------------

typedef struct {
    int negativeCount;          // "Show fewer" / "Don't recommend" interactions.
    long long firstEventUnix;
    long long lastEventUnix;
    bool suppressed;
    bool restoredByUser;        // User restored: requires a fresh streak.
} MTPCreatorRecord;

typedef struct {
    int threshold;              // Interactions required (always clamped to >= 2).
    long long windowSeconds;    // Interactions older than this decay (<=0: never).
    bool autoSuppress;
} MTPSuppressionPolicy;

/// Clamps a user-provided threshold. A single interaction must never suppress.
int mtp_clamp_threshold(int threshold);

/// Registers one negative interaction. Returns true if this event caused the
/// creator to become suppressed.
bool mtp_record_negative_feedback(MTPCreatorRecord *record, const MTPSuppressionPolicy *policy, long long nowUnix);

/// Restores the creator: clears suppression and the streak.
void mtp_restore_creator(MTPCreatorRecord *record);

typedef enum {
    MTPSurfaceHome = 0,
    MTPSurfaceShorts,
    MTPSurfaceWatchNext,
    MTPSurfaceExplore,
    MTPSurfaceSubscriptions,
    MTPSurfaceSearch,
    MTPSurfaceChannelSearch,  // dedicated channel / user search results
    MTPSurfaceChannelPage,
    MTPSurfaceOther,
} MTPSurface;

/// Suppressed creators are hidden from recommendation surfaces only. Search,
/// channel search and channel pages always stay reachable.
bool mtp_surface_allows_suppression(MTPSurface surface);

// ---------------------------------------------------------------------------
// DeArrow
// ---------------------------------------------------------------------------

/// Applies DeArrow's title formatting rules in place: strips the leading ">"
/// marker used by the DeArrow API for "original-cased" words and collapses
/// whitespace. Returns the new length.
size_t mtp_dearrow_clean_title(char *title);

/// Deterministic cache key bucket (0..buckets-1) used to shard the disk cache.
uint32_t mtp_fnv1a(const char *text);

// ---------------------------------------------------------------------------
// Navigation / dock
// ---------------------------------------------------------------------------

#define MTP_MAX_TABS 16
#define MTP_TAB_ID_LEN 48

typedef struct {
    char identifiers[MTP_MAX_TABS][MTP_TAB_ID_LEN];
    size_t count;
} MTPTabList;

void mtp_tabs_init(MTPTabList *list);
bool mtp_tabs_append(MTPTabList *list, const char *identifier);
long mtp_tabs_index_of(const MTPTabList *list, const char *identifier);
bool mtp_tabs_remove(MTPTabList *list, const char *identifier);

/// Computes the final dock arrangement.
///   present   - tabs the server sent, in server order
///   order     - user's preferred order (may reference absent tabs)
///   hidden    - tabs the user hid
///   injectable- absent tabs we are allowed to synthesise (e.g. FEsubscriptions)
/// Result: user order first (only tabs that exist or can be injected and are
/// not hidden), followed by remaining server tabs in server order. The first
/// server tab is never removed if that would leave the dock empty.
void mtp_tabs_arrange(const MTPTabList *present, const MTPTabList *order,
                      const MTPTabList *hidden, const MTPTabList *injectable,
                      MTPTabList *result);

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

/// Exponential back-off for retries (seconds), capped.
double mtp_retry_delay(int attempt, double base, double cap);

/// Picks the best format index for a requested max height.
///   heights/isAudio/bitrates describe `count` formats.
///   wantAudioOnly - choose highest bitrate audio.
/// Returns -1 if nothing matches.
long mtp_pick_format(const int *heights, const bool *isAudio, const long *bitrates,
                     size_t count, int maxHeight, bool wantAudioOnly);

// ---------------------------------------------------------------------------
// Protocol-buffer helpers (YouTube element / renderer bytes)
// ---------------------------------------------------------------------------

/// Finds video IDs referenced by i.ytimg.com thumbnail paths ("/vi/<id>/",
/// "/vi_webp/<id>/"), which every video cell carries. Calls back once per
/// distinct ID in order of appearance. Returns the number of IDs.
size_t mtp_scan_thumbnail_video_ids(const uint8_t *bytes, size_t length,
                                    void (*callback)(const char *videoID, void *context),
                                    void *context);

/// True if `bytes` contains `value` encoded as a complete length-delimited
/// protobuf field (tag with wire type 2, varint length == valueLength).
/// Used to match channel names/IDs exactly instead of by substring.
bool mtp_pb_contains_string_field(const uint8_t *bytes, size_t length,
                                  const char *value, size_t valueLength);

/// YouTube search "sp" parameter codes.
typedef enum { MTPUploadAny = 0, MTPUploadHour = 1, MTPUploadToday = 2, MTPUploadWeek = 3, MTPUploadMonth = 4, MTPUploadYear = 5 } MTPUploadCode;
typedef enum { MTPDurationAny = 0, MTPDurationShort = 1, MTPDurationLong = 2, MTPDurationMedium = 3 } MTPDurationCode;

/// Smallest server-side upload bucket that contains `maxAgeSeconds`.
MTPUploadCode mtp_upload_code_for_age(long long maxAgeSeconds);
/// Server duration bucket that is a superset of [min,max] (or Any).
MTPDurationCode mtp_duration_code_for_range(long minSeconds, long maxSeconds);

/// Encodes YouTube's search params protobuf (before base64). Returns the
/// number of bytes written, or 0 if nothing needs to be sent.
size_t mtp_search_params_encode(bool sortByUploadDate, MTPUploadCode upload, MTPDurationCode duration,
                                uint8_t *out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
