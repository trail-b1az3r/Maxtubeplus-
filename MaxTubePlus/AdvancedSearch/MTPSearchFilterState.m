#import "MTPSearchFilterState.h"

static NSString *FormatDuration(long seconds) {
    if (seconds >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", seconds / 3600, (seconds / 60) % 60, seconds % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", seconds / 60, seconds % 60];
}

static NSString *FormatAge(long long seconds) {
    if (seconds <= 3600) return @"last hour";
    if (seconds <= 86400) return @"today";
    if (seconds <= 7 * 86400) return @"this week";
    if (seconds <= 31 * 86400) return @"this month";
    if (seconds <= 366 * 86400) return @"this year";
    return [NSString stringWithFormat:@"last %lld days", seconds / 86400];
}

static void CaptureFirstVideoID(const char *videoID, void *context) {
    char *out = context;
    if (!out[0]) strncpy(out, videoID, 11);
}

@implementation MTPSearchFilterState

+ (instancetype)shared {
    static MTPSearchFilterState *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; [shared load]; });
    return shared;
}

- (void)load {
    NSDictionary *d = [MTPPrefs objectForKey:MTPKeySearchFilterState];
    if (![d isKindOfClass:[NSDictionary class]]) d = @{};
    _minLikes = d[@"minLikes"] ? [d[@"minLikes"] longLongValue] : -1;
    _minDuration = d[@"minDuration"] ? [d[@"minDuration"] longValue] : -1;
    _maxDuration = d[@"maxDuration"] ? [d[@"maxDuration"] longValue] : -1;
    _maxAge = d[@"maxAge"] ? [d[@"maxAge"] longLongValue] : -1;
    _uploadedAfter = [d[@"after"] isKindOfClass:[NSDate class]] ? d[@"after"] : nil;
    _uploadedBefore = [d[@"before"] isKindOfClass:[NSDate class]] ? d[@"before"] : nil;
    _sortMode = (MTPSortMode)[MTPPrefs integerForKey:MTPKeySearchSortMode];
}

- (void)save {
    NSMutableDictionary *d = [@{@"minLikes": @(_minLikes), @"minDuration": @(_minDuration), @"maxDuration": @(_maxDuration), @"maxAge": @(_maxAge)} mutableCopy];
    if (_uploadedAfter) d[@"after"] = _uploadedAfter;
    if (_uploadedBefore) d[@"before"] = _uploadedBefore;
    [MTPPrefs setObject:d forKey:MTPKeySearchFilterState];
    [MTPPrefs setInteger:_sortMode forKey:MTPKeySearchSortMode];
}

- (MTPSearchFilter)cFilter {
    MTPSearchFilter f;
    mtp_filter_reset(&f);
    f.minLikes = _minLikes;
    f.minDurationSeconds = _minDuration;
    f.maxDurationSeconds = _maxDuration;
    f.maxAgeSeconds = _maxAge;
    f.uploadedAfterUnix = _uploadedAfter ? (long long)_uploadedAfter.timeIntervalSince1970 : -1;
    f.uploadedBeforeUnix = _uploadedBefore ? (long long)_uploadedBefore.timeIntervalSince1970 : -1;
    return f;
}

- (BOOL)hasActiveFilters {
    MTPSearchFilter f = [self cFilter];
    return mtp_filter_is_active(&f);
}

- (NSArray<NSNumber *> *)activeKinds {
    NSMutableArray *kinds = [NSMutableArray array];
    if (_minLikes >= 0) [kinds addObject:@(MTPFilterKindMinLikes)];
    if (_minDuration >= 0) [kinds addObject:@(MTPFilterKindMinDuration)];
    if (_maxDuration >= 0) [kinds addObject:@(MTPFilterKindMaxDuration)];
    if (_maxAge >= 0) [kinds addObject:@(MTPFilterKindRecency)];
    if (_uploadedAfter || _uploadedBefore) [kinds addObject:@(MTPFilterKindUploadWindow)];
    return kinds;
}

- (NSString *)descriptionForKind:(MTPFilterKind)kind {
    switch (kind) {
        case MTPFilterKindMinLikes:
            return [NSString stringWithFormat:@"≥ %@ likes", [NSNumberFormatter localizedStringFromNumber:@(_minLikes) numberStyle:NSNumberFormatterDecimalStyle]];
        case MTPFilterKindMinDuration: return [@"Longer than " stringByAppendingString:FormatDuration(_minDuration)];
        case MTPFilterKindMaxDuration: return [@"Shorter than " stringByAppendingString:FormatDuration(_maxDuration)];
        case MTPFilterKindRecency: return [@"Uploaded " stringByAppendingString:FormatAge(_maxAge)];
        case MTPFilterKindUploadWindow: {
            NSString *a = _uploadedAfter ? [NSDateFormatter localizedStringFromDate:_uploadedAfter dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle] : @"…";
            NSString *b = _uploadedBefore ? [NSDateFormatter localizedStringFromDate:_uploadedBefore dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterNoStyle] : @"now";
            return [NSString stringWithFormat:@"Uploaded %@ – %@", a, b];
        }
    }
    return @"";
}

- (void)removeKind:(MTPFilterKind)kind {
    switch (kind) {
        case MTPFilterKindMinLikes: _minLikes = -1; break;
        case MTPFilterKindMinDuration: _minDuration = -1; break;
        case MTPFilterKindMaxDuration: _maxDuration = -1; break;
        case MTPFilterKindRecency: _maxAge = -1; break;
        case MTPFilterKindUploadWindow: _uploadedAfter = nil; _uploadedBefore = nil; break;
    }
    [self save];
}

- (void)clearAll {
    _minLikes = -1; _minDuration = -1; _maxDuration = -1; _maxAge = -1;
    _uploadedAfter = nil; _uploadedBefore = nil;
    [self save]; // sort mode is intentionally preserved
}

- (NSString *)encodedSearchParams {
    long long age = _maxAge;
    if (_uploadedAfter) {
        long long sinceAfter = (long long)-[_uploadedAfter timeIntervalSinceNow];
        if (age < 0 || sinceAfter < age) age = sinceAfter;
    }
    MTPUploadCode upload = mtp_upload_code_for_age(age);
    MTPDurationCode duration = mtp_duration_code_for_range(_minDuration, _maxDuration);
    uint8_t buffer[16];
    size_t length = mtp_search_params_encode(_sortMode == MTPSortRecency, upload, duration, buffer, sizeof(buffer));
    if (length == 0) return nil;
    NSString *base64 = [[NSData dataWithBytes:buffer length:length] base64EncodedStringWithOptions:0];
    return [base64 stringByReplacingOccurrencesOfString:@"=" withString:@"%3D"];
}

+ (MTPVideoFacts)factsFromElementBytes:(NSData *)bytes videoID:(NSString **)videoIDOut {
    MTPVideoFacts facts = {.durationSeconds = -1, .likes = -1, .ageSeconds = -1};
    // ISO Latin-1 maps every byte to one character, so offsets are preserved
    // and ASCII text (durations, "3 days ago") is readable.
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSISOLatin1StringEncoding];
    if (!text) return facts;
    static NSRegularExpression *durationRegex, *ageRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        durationRegex = [NSRegularExpression regularExpressionWithPattern:@"(?<![0-9:])(?:[0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}(?![0-9:])" options:0 error:nil];
        ageRegex = [NSRegularExpression regularExpressionWithPattern:@"[0-9]+ (?:second|minute|hour|day|week|month|year)s? ago" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *d = [durationRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (d) facts.durationSeconds = mtp_parse_duration([text substringWithRange:d.range].UTF8String);
    NSTextCheckingResult *a = [ageRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (a) facts.ageSeconds = mtp_parse_relative_age([text substringWithRange:a.range].UTF8String);
    char first[12] = {0};
    mtp_scan_thumbnail_video_ids(bytes.bytes, bytes.length, CaptureFirstVideoID, first);
    NSString *videoID = first[0] ? @(first) : nil;
    if (videoID) facts.likes = [[MTPLikesProvider shared] cachedLikesForVideoID:videoID];
    if (videoIDOut) *videoIDOut = videoID;
    return facts;
}

@end

@implementation MTPLikesProvider {
    NSMutableDictionary<NSString *, NSNumber *> *_likes;
    NSMutableSet<NSString *> *_inFlight;
    NSURLSession *_session;
}

+ (instancetype)shared {
    static MTPLikesProvider *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _likes = [NSMutableDictionary dictionary];
        _inFlight = [NSMutableSet set];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 8;
        config.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

- (long long)cachedLikesForVideoID:(NSString *)videoID {
    @synchronized (_likes) {
        NSNumber *n = _likes[videoID];
        return n ? n.longLongValue : -1;
    }
}

- (void)fetchLikesForVideoIDs:(NSArray<NSString *> *)videoIDs completion:(void (^)(void))completion {
    dispatch_group_t group = dispatch_group_create();
    for (NSString *videoID in videoIDs) {
        @synchronized (_likes) {
            if (_likes[videoID] || [_inFlight containsObject:videoID]) continue;
            [_inFlight addObject:videoID];
        }
        dispatch_group_enter(group);
        NSURL *url = [NSURL URLWithString:[@"https://returnyoutubedislikeapi.com/votes?videoId=" stringByAppendingString:videoID]];
        [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            @synchronized (self->_likes) {
                if ([json isKindOfClass:[NSDictionary class]] && [json[@"likes"] isKindOfClass:[NSNumber class]]) self->_likes[videoID] = json[@"likes"];
                [self->_inFlight removeObject:videoID];
            }
            dispatch_group_leave(group);
        }] resume];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), completion);
}

@end
