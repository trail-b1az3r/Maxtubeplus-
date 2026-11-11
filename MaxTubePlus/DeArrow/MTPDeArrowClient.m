#import "MTPDeArrowClient.h"

static NSString *const kBrandingEndpoint = @"https://sponsor.ajay.app/api/branding";
static NSString *const kThumbnailEndpoint = @"https://dearrow-thumb.ajay.app/api/v1/getThumbnail";
static const NSTimeInterval kHitTTL = 6 * 3600;   // submissions change; refresh periodically
static const NSTimeInterval kMissTTL = 2 * 3600;  // no submission yet

@implementation MTPDeArrowBranding

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_videoID forKey:@"v"];
    [coder encodeObject:_title forKey:@"t"];
    [coder encodeObject:_thumbnailTime forKey:@"th"];
    [coder encodeObject:_fetchedAt forKey:@"f"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) {
        _videoID = [coder decodeObjectOfClass:[NSString class] forKey:@"v"] ?: @"";
        _title = [coder decodeObjectOfClass:[NSString class] forKey:@"t"];
        _thumbnailTime = [coder decodeObjectOfClass:[NSNumber class] forKey:@"th"];
        _fetchedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"f"] ?: [NSDate distantPast];
    }
    return self;
}

- (NSURL *)thumbnailURL {
    if (!_thumbnailTime) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:kThumbnailEndpoint];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"videoID" value:_videoID],
        [NSURLQueryItem queryItemWithName:@"time" value:_thumbnailTime.stringValue],
    ];
    return components.URL;
}

- (BOOL)isFresh {
    NSTimeInterval ttl = (_title || _thumbnailTime) ? kHitTTL : kMissTTL;
    return -[_fetchedAt timeIntervalSinceNow] < ttl;
}

@end

@implementation MTPDeArrowClient {
    NSCache<NSString *, MTPDeArrowBranding *> *_memory;
    NSMutableDictionary<NSString *, NSMutableArray *> *_pending;
    NSURLSession *_session;
    NSString *_directory;
    dispatch_queue_t _ioQueue;
}

+ (instancetype)shared {
    static MTPDeArrowClient *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _memory = [NSCache new];
        _memory.countLimit = 4000;
        _pending = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.HTTPMaximumConnectionsPerHost = 4;
        config.timeoutIntervalForRequest = 10;
        config.HTTPAdditionalHeaders = @{@"User-Agent": [NSString stringWithFormat:@"MaxTubePlus/%s (iOS; DeArrow client)", MTP_VERSION]};
        _session = [NSURLSession sessionWithConfiguration:config];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        _directory = [caches stringByAppendingPathComponent:@"MaxTubePlus/DeArrow"];
        _ioQueue = dispatch_queue_create("com.maxtubeplus.dearrow.io", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)pathFor:(NSString *)videoID {
    NSString *bucket = [NSString stringWithFormat:@"%02x", mtp_fnv1a(videoID.UTF8String) & 0xFF];
    return [[_directory stringByAppendingPathComponent:bucket] stringByAppendingPathComponent:videoID];
}

+ (MTPDeArrowBranding *)parseBrandingJSON:(NSData *)data videoID:(NSString *)videoID {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    MTPDeArrowBranding *branding = [MTPDeArrowBranding new];
    branding.videoID = videoID;
    branding.fetchedAt = [NSDate date];

    // DeArrow returns submissions best-first. A submission is trusted when it
    // is locked or has non-negative votes; an "original" submission means the
    // community voted to keep YouTube's own title/thumbnail.
    NSArray *titles = [json[@"titles"] isKindOfClass:[NSArray class]] ? json[@"titles"] : @[];
    for (NSDictionary *entry in titles) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        BOOL trusted = [entry[@"locked"] boolValue] || [entry[@"votes"] integerValue] >= 0;
        if (!trusted) continue;
        if ([entry[@"original"] boolValue]) break;
        NSString *title = entry[@"title"];
        if (![title isKindOfClass:[NSString class]] || title.length == 0) continue;
        NSMutableData *buffer = [[title dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [buffer appendBytes:"\0" length:1];
        size_t len = mtp_dearrow_clean_title(buffer.mutableBytes);
        branding.title = [[NSString alloc] initWithBytes:buffer.bytes length:len encoding:NSUTF8StringEncoding];
        break;
    }
    NSArray *thumbnails = [json[@"thumbnails"] isKindOfClass:[NSArray class]] ? json[@"thumbnails"] : @[];
    for (NSDictionary *entry in thumbnails) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        BOOL trusted = [entry[@"locked"] boolValue] || [entry[@"votes"] integerValue] >= 0;
        if (!trusted) continue;
        if ([entry[@"original"] boolValue]) break;
        id timestamp = entry[@"timestamp"];
        if ([timestamp isKindOfClass:[NSNumber class]]) {
            branding.thumbnailTime = timestamp;
            break;
        }
    }
    // No submissions: fall back to the originals (we deliberately do NOT use
    // DeArrow's "randomTime" auto-thumbnail).
    return branding;
}

- (MTPDeArrowBranding *)cachedBrandingForVideoID:(NSString *)videoID {
    if (!mtp_is_video_id(videoID.UTF8String)) return nil;
    MTPDeArrowBranding *branding = [_memory objectForKey:videoID];
    if (branding) return branding;
    NSData *data = [NSData dataWithContentsOfFile:[self pathFor:videoID]];
    if (!data) return nil;
    branding = [NSKeyedUnarchiver unarchivedObjectOfClass:[MTPDeArrowBranding class] fromData:data error:nil];
    if (branding) [_memory setObject:branding forKey:videoID];
    return branding;
}

- (void)store:(MTPDeArrowBranding *)branding {
    [_memory setObject:branding forKey:branding.videoID];
    NSString *path = [self pathFor:branding.videoID];
    dispatch_async(_ioQueue, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:branding requiringSecureCoding:YES error:nil];
        [data writeToFile:path atomically:YES];
    });
}

- (void)brandingForVideoID:(NSString *)videoID completion:(void (^)(MTPDeArrowBranding *))completion {
    if (!mtp_is_video_id(videoID.UTF8String)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    MTPDeArrowBranding *cached = [self cachedBrandingForVideoID:videoID];
    if (cached && [cached isFresh]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    @synchronized (_pending) {
        NSMutableArray *waiters = _pending[videoID];
        if (waiters) { if (completion) [waiters addObject:[completion copy]]; return; }
        _pending[videoID] = completion ? [NSMutableArray arrayWithObject:[completion copy]] : [NSMutableArray array];
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:kBrandingEndpoint];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"videoID" value:videoID]];
    _requestCount++;
    [[_session dataTaskWithURL:components.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        MTPDeArrowBranding *branding = nil;
        if (!error && status == 200 && data) {
            branding = [MTPDeArrowClient parseBrandingJSON:data videoID:videoID];
        } else if (status == 404) {
            // 404 == no submissions for this video.
            branding = [MTPDeArrowBranding new];
            branding.videoID = videoID;
            branding.fetchedAt = [NSDate date];
        } else {
            branding = cached; // network error: keep stale data rather than flicker
        }
        if (branding && branding != cached) [self store:branding];
        if (branding.title || branding.thumbnailTime) self->_replacementCount++;
        NSArray *waiters;
        @synchronized (self->_pending) {
            waiters = self->_pending[videoID];
            [self->_pending removeObjectForKey:videoID];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^waiter)(MTPDeArrowBranding *) in waiters) waiter(branding);
        });
    }] resume];
}

- (void)clearCache {
    [_memory removeAllObjects];
    dispatch_async(_ioQueue, ^{ [[NSFileManager defaultManager] removeItemAtPath:self->_directory error:nil]; });
}

@end
