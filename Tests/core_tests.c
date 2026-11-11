// Host-side unit tests for MaxTubePlus/Core. Run with Tests/run_tests.sh.
// These run on Linux/macOS without iOS frameworks; they test logic only, not
// in-app behaviour (that requires a device, see docs/TESTING.md).

#include "../MaxTubePlus/Core/MTPCore.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void test_versions(void) {
    CHECK(mtp_version_compare("21.42.4", "21.42.4") == 0);
    CHECK(mtp_version_compare("21.42.4", "21.43") < 0);
    CHECK(mtp_version_compare("21.43", "21.42.10") > 0);
    CHECK(mtp_version_compare("21.42", "21.42.0") == 0);
    CHECK(mtp_compat_level("21.42.4", "21.42.4", "21.30.0") == MTPCompatVerified);
    CHECK(mtp_compat_level("21.43.5", "21.42.4", "21.30.0") == MTPCompatSameMajor);
    CHECK(mtp_compat_level("20.21.6", "21.42.4", "21.30.0") == MTPCompatUnsupported);
    CHECK(mtp_compat_level("22.01.1", "21.42.4", "21.30.0") == MTPCompatUnsupported);
    CHECK(mtp_compat_level("", "21.42.4", "21.30.0") == MTPCompatUnknown);
    CHECK(mtp_compat_level(NULL, "21.42.4", "21.30.0") == MTPCompatUnknown);
}

static void test_parsing(void) {
    CHECK(mtp_parse_duration("12:34") == 754);
    CHECK(mtp_parse_duration("1:02:03") == 3723);
    CHECK(mtp_parse_duration("0:59") == 59);
    CHECK(mtp_parse_duration("LIVE") == -1);
    CHECK(mtp_parse_duration("12") == -1);
    CHECK(mtp_parse_duration("1:75") == -1);
    CHECK(mtp_parse_count("1.2K") == 1200);
    CHECK(mtp_parse_count("3M likes") == 3000000);
    CHECK(mtp_parse_count("12,345") == 12345);
    CHECK(mtp_parse_count("1.5B") == 1500000000LL);
    CHECK(mtp_parse_count("987 likes") == 987);
    CHECK(mtp_parse_count("no likes") == -1);
    CHECK(mtp_parse_relative_age("3 days ago") == 3 * 86400);
    CHECK(mtp_parse_relative_age("Streamed 2 weeks ago") == 2 * 604800);
    CHECK(mtp_parse_relative_age("1 year ago") == 31557600);
    CHECK(mtp_parse_relative_age("5 minutes ago") == 300);
    CHECK(mtp_parse_relative_age("yesterday") == -1);
    CHECK(mtp_is_video_id("dQw4w9WgXcQ"));
    CHECK(!mtp_is_video_id("dQw4w9WgXc"));
    CHECK(mtp_is_channel_id("UCuAXFkgsw1L7xaCfnd5JJOw", 24));
    CHECK(!mtp_is_channel_id("UCuAXFkgsw1L7xaCfnd5JJO", 23));
}

static int scanned;
static char lastID[25];
static void on_id(const char *id, void *ctx) { (void)ctx; scanned++; strcpy(lastID, id); }

static void test_scan(void) {
    const char *blob = "browseId: \"UCuAXFkgsw1L7xaCfnd5JJOw\" foo XUCuAXFkgsw1L7xaCfnd5JJOw UC_x5XG1OV2P6uZZ5FSM9Ttw";
    scanned = 0;
    size_t n = mtp_scan_channel_ids(blob, strlen(blob), on_id, NULL);
    CHECK(n == 2);
    CHECK(scanned == 2);
    CHECK(strcmp(lastID, "UC_x5XG1OV2P6uZZ5FSM9Ttw") == 0);
}

static void test_filters(void) {
    MTPSearchFilter f;
    mtp_filter_reset(&f);
    CHECK(!mtp_filter_is_active(&f));
    MTPVideoFacts v = { .durationSeconds = 600, .likes = 5000, .ageSeconds = 86400 * 3 };
    CHECK(mtp_filter_evaluate(&f, &v, 1700000000) == MTPFilterPass);

    f.minDurationSeconds = 240;
    f.maxDurationSeconds = 1200;
    f.minLikes = 1000;
    f.maxAgeSeconds = 86400 * 7;
    CHECK(mtp_filter_active_count(&f) == 4);
    CHECK(mtp_filter_evaluate(&f, &v, 1700000000) == MTPFilterPass);

    MTPVideoFacts shortVid = v; shortVid.durationSeconds = 60;
    CHECK(mtp_filter_evaluate(&f, &shortVid, 1700000000) == MTPFilterRejectDurationShort);
    MTPVideoFacts longVid = v; longVid.durationSeconds = 4000;
    CHECK(mtp_filter_evaluate(&f, &longVid, 1700000000) == MTPFilterRejectDurationLong);
    MTPVideoFacts fewLikes = v; fewLikes.likes = 10;
    CHECK(mtp_filter_evaluate(&f, &fewLikes, 1700000000) == MTPFilterRejectLikes);
    MTPVideoFacts old = v; old.ageSeconds = 86400 * 30;
    CHECK(mtp_filter_evaluate(&f, &old, 1700000000) == MTPFilterRejectAge);
    MTPVideoFacts unknownLikes = v; unknownLikes.likes = -1;
    CHECK(mtp_filter_evaluate(&f, &unknownLikes, 1700000000) == MTPFilterUnknown);

    // Individual removal keeps others.
    f.minLikes = -1;
    CHECK(mtp_filter_active_count(&f) == 3);
    CHECK(mtp_filter_evaluate(&f, &fewLikes, 1700000000) == MTPFilterPass);

    // Upload window.
    mtp_filter_reset(&f);
    f.uploadedAfterUnix = 1700000000 - 86400 * 5;
    CHECK(mtp_filter_evaluate(&f, &v, 1700000000) == MTPFilterPass);
    CHECK(mtp_filter_evaluate(&f, &old, 1700000000) == MTPFilterRejectUploadWindow);
}

static void test_sort(void) {
    MTPSortKey keys[4] = {{0, 500}, {1, -1}, {2, 100}, {3, 500}};
    mtp_sort_keys(keys, 4, MTPSortRecency);
    CHECK(keys[0].originalIndex == 2);
    CHECK(keys[1].originalIndex == 0);
    CHECK(keys[2].originalIndex == 3);
    CHECK(keys[3].originalIndex == 1);
    mtp_sort_keys(keys, 4, MTPSortRelevance);
    for (size_t i = 0; i < 4; i++) CHECK(keys[i].originalIndex == i);
}

static void test_suppression(void) {
    MTPSuppressionPolicy p = { .threshold = 1, .windowSeconds = 0, .autoSuppress = true };
    MTPCreatorRecord r = {0};
    // Threshold 1 must be clamped: one interaction never suppresses.
    CHECK(!mtp_record_negative_feedback(&r, &p, 100));
    CHECK(!r.suppressed);
    CHECK(mtp_record_negative_feedback(&r, &p, 200));
    CHECK(r.suppressed);

    mtp_restore_creator(&r);
    CHECK(!r.suppressed && r.negativeCount == 0 && r.restoredByUser);

    p.threshold = 3;
    p.windowSeconds = 1000;
    MTPCreatorRecord d = {0};
    CHECK(!mtp_record_negative_feedback(&d, &p, 0));
    CHECK(!mtp_record_negative_feedback(&d, &p, 500));
    // Gap larger than window resets the streak.
    CHECK(!mtp_record_negative_feedback(&d, &p, 5000));
    CHECK(d.negativeCount == 1);
    CHECK(!mtp_record_negative_feedback(&d, &p, 5100));
    CHECK(mtp_record_negative_feedback(&d, &p, 5200));

    MTPSuppressionPolicy off = { .threshold = 2, .windowSeconds = 0, .autoSuppress = false };
    MTPCreatorRecord o = {0};
    for (int i = 0; i < 10; i++) CHECK(!mtp_record_negative_feedback(&o, &off, i));
    CHECK(!o.suppressed && o.negativeCount == 10);

    CHECK(mtp_surface_allows_suppression(MTPSurfaceHome));
    CHECK(mtp_surface_allows_suppression(MTPSurfaceShorts));
    CHECK(!mtp_surface_allows_suppression(MTPSurfaceSearch));
    CHECK(!mtp_surface_allows_suppression(MTPSurfaceChannelSearch));
    CHECK(!mtp_surface_allows_suppression(MTPSurfaceChannelPage));
    CHECK(mtp_clamp_threshold(0) == 2 && mtp_clamp_threshold(100) == 20);
}

static void test_dearrow(void) {
    char t1[] = "  >iPhone 16   review: is it  worth it? ";
    mtp_dearrow_clean_title(t1);
    CHECK(strcmp(t1, "iPhone 16 review: is it worth it?") == 0);
    char t2[] = "a > b";
    mtp_dearrow_clean_title(t2);
    CHECK(strcmp(t2, "a > b") == 0);
    CHECK(mtp_fnv1a("abc") == mtp_fnv1a("abc"));
    CHECK(mtp_fnv1a("abc") != mtp_fnv1a("abd"));
}

static void list(MTPTabList *l, const char **ids, size_t n) {
    mtp_tabs_init(l);
    for (size_t i = 0; i < n; i++) mtp_tabs_append(l, ids[i]);
}

static void test_tabs(void) {
    MTPTabList present, order, hidden, inject, result;
    // Floating-menu redesign: server dropped FEsubscriptions.
    const char *server[] = {"FEwhat_to_watch", "FEshorts", "FEuploads", "FElibrary"};
    list(&present, server, 4);
    const char *userOrder[] = {"FEwhat_to_watch", "FEsubscriptions", "FEshorts", "FElibrary"};
    list(&order, userOrder, 4);
    const char *h[] = {"FEuploads"};
    list(&hidden, h, 1);
    const char *inj[] = {"FEsubscriptions"};
    list(&inject, inj, 1);

    mtp_tabs_arrange(&present, &order, &hidden, &inject, &result);
    CHECK(result.count == 4);
    CHECK(strcmp(result.identifiers[0], "FEwhat_to_watch") == 0);
    CHECK(strcmp(result.identifiers[1], "FEsubscriptions") == 0);
    CHECK(strcmp(result.identifiers[2], "FEshorts") == 0);
    CHECK(strcmp(result.identifiers[3], "FElibrary") == 0);

    // Hiding subscriptions keeps it out even though it is injectable.
    mtp_tabs_append(&hidden, "FEsubscriptions");
    mtp_tabs_arrange(&present, &order, &hidden, &inject, &result);
    CHECK(mtp_tabs_index_of(&result, "FEsubscriptions") < 0);

    // Hiding everything leaves the first server tab.
    MTPTabList all;
    list(&all, server, 4);
    mtp_tabs_arrange(&present, NULL, &all, NULL, &result);
    CHECK(result.count == 1 && strcmp(result.identifiers[0], "FEwhat_to_watch") == 0);

    // No duplicates; unknown tabs without injection are dropped.
    const char *weird[] = {"FEshorts", "FEshorts", "FEnot_real"};
    list(&order, weird, 3);
    mtp_tabs_arrange(&present, &order, NULL, NULL, &result);
    CHECK(result.count == 4);
    CHECK(strcmp(result.identifiers[0], "FEshorts") == 0);
    CHECK(mtp_tabs_index_of(&result, "FEnot_real") < 0);

    CHECK(mtp_tabs_remove(&present, "FEshorts"));
    CHECK(present.count == 3 && mtp_tabs_index_of(&present, "FEshorts") < 0);
}

static void test_downloads(void) {
    CHECK(mtp_retry_delay(0, 2, 60) == 2);
    CHECK(mtp_retry_delay(3, 2, 60) == 16);
    CHECK(mtp_retry_delay(10, 2, 60) == 60);
    int heights[] = {360, 720, 1080, 0, 0};
    bool audio[] = {false, false, false, true, true};
    long bitrates[] = {500, 1500, 3000, 128, 160};
    CHECK(mtp_pick_format(heights, audio, bitrates, 5, 720, false) == 1);
    CHECK(mtp_pick_format(heights, audio, bitrates, 5, 0, false) == 2);
    CHECK(mtp_pick_format(heights, audio, bitrates, 5, 144, false) == 0);
    CHECK(mtp_pick_format(heights, audio, bitrates, 5, 0, true) == 4);
}

static int vidCount;
static char vids[4][12];
static void on_vid(const char *id, void *ctx) { (void)ctx; if (vidCount < 4) strcpy(vids[vidCount], id); vidCount++; }

static void test_protobuf(void) {
    const char blob[] = "\x0a\x30https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg?x\x12\x05Hello"
                        "https://i.ytimg.com/vi_webp/abcdefghijk/mq.webp https://i.ytimg.com/vi/dQw4w9WgXcQ/0.jpg /vi/short/";
    vidCount = 0;
    size_t n = mtp_scan_thumbnail_video_ids((const uint8_t *)blob, sizeof(blob) - 1, on_vid, NULL);
    CHECK(n == 2 && vidCount == 2);
    CHECK(strcmp(vids[0], "dQw4w9WgXcQ") == 0);
    CHECK(strcmp(vids[1], "abcdefghijk") == 0);

    const uint8_t pb[] = {0x0a, 0x03, 'f', 'o', 'o', 0x12, 0x07, 'M', 'r', 'B', 'e', 'a', 's', 't', 0x1a, 0x09, 'M', 'r', 'B', 'e', 'a', 's', 't', 'X', 'Y'};
    CHECK(mtp_pb_contains_string_field(pb, sizeof(pb), "MrBeast", 7));
    CHECK(mtp_pb_contains_string_field(pb, sizeof(pb), "foo", 3));
    CHECK(!mtp_pb_contains_string_field(pb, sizeof(pb), "MrBeastX", 8));
    CHECK(!mtp_pb_contains_string_field(pb, sizeof(pb), "Beast", 5));

    uint8_t out[16];
    // Known YouTube values: "EgIQAQ==" (videos), "CAI=" (sort by upload date).
    size_t len = mtp_search_params_encode(true, MTPUploadAny, MTPDurationAny, out, sizeof(out));
    CHECK(len == 2 && out[0] == 0x08 && out[1] == 0x02);
    len = mtp_search_params_encode(false, MTPUploadWeek, MTPDurationMedium, out, sizeof(out));
    const uint8_t expect[] = {0x12, 0x06, 0x08, 0x03, 0x10, 0x01, 0x18, 0x03};
    CHECK(len == sizeof(expect) && memcmp(out, expect, len) == 0);
    CHECK(mtp_search_params_encode(false, MTPUploadAny, MTPDurationAny, out, sizeof(out)) == 0);
    CHECK(mtp_upload_code_for_age(3 * 86400) == MTPUploadWeek);
    CHECK(mtp_upload_code_for_age(-1) == MTPUploadAny);
    CHECK(mtp_duration_code_for_range(300, 900) == MTPDurationMedium);
    CHECK(mtp_duration_code_for_range(1500, -1) == MTPDurationLong);
    CHECK(mtp_duration_code_for_range(-1, 120) == MTPDurationShort);
    CHECK(mtp_duration_code_for_range(60, 900) == MTPDurationAny);
}

int main(void) {
    test_protobuf();
    test_versions();
    test_parsing();
    test_scan();
    test_filters();
    test_sort();
    test_suppression();
    test_dearrow();
    test_tabs();
    test_downloads();
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
