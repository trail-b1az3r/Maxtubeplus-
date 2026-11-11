#import "MTPVideoInfo.h"

@implementation MTPVideoInfo

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_videoID forKey:@"v"];
    [coder encodeObject:_title forKey:@"t"];
    [coder encodeObject:_authorName forKey:@"a"];
    [coder encodeObject:_authorURL forKey:@"u"];
    [coder encodeObject:_thumbnailURL forKey:@"th"];
    [coder encodeBool:_unavailable forKey:@"x"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) {
        _videoID = [coder decodeObjectOfClass:[NSString class] forKey:@"v"] ?: @"";
        _title = [coder decodeObjectOfClass:[NSString class] forKey:@"t"];
        _authorName = [coder decodeObjectOfClass:[NSString class] forKey:@"a"];
        _authorURL = [coder decodeObjectOfClass:[NSString class] forKey:@"u"];
        _thumbnailURL = [coder decodeObjectOfClass:[NSString class] forKey:@"th"];
        _unavailable = [coder decodeBoolForKey:@"x"];
    }
    return self;
}

@end

@implementation MTPVideoInfoProvider {
    NSCache<NSString *, MTPVideoInfo *> *_memory;
    NSMutableDictionary<NSString *, NSMutableArray *> *_pending;
    NSURLSession *_session;
    NSString *_directory;
}

+ (instancetype)shared {
    static MTPVideoInfoProvider *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _memory = [NSCache new];
        _memory.countLimit = 2000;
        _pending = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPMaximumConnectionsPerHost = 4;
        config.timeoutIntervalForRequest = 15;
        _session = [NSURLSession sessionWithConfiguration:config];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        _directory = [caches stringByAppendingPathComponent:@"MaxTubePlus/VideoInfo"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

- (NSString *)pathFor:(NSString *)videoID {
    return [_directory stringByAppendingPathComponent:[videoID stringByAppendingPathExtension:@"plist"]];
}

- (MTPVideoInfo *)cachedInfoForVideoID:(NSString *)videoID {
    if (!mtp_is_video_id(videoID.UTF8String)) return nil;
    MTPVideoInfo *info = [_memory objectForKey:videoID];
    if (info) return info;
    NSData *data = [NSData dataWithContentsOfFile:[self pathFor:videoID]];
    if (!data) return nil;
    info = [NSKeyedUnarchiver unarchivedObjectOfClass:[MTPVideoInfo class] fromData:data error:nil];
    if (info) [_memory setObject:info forKey:videoID];
    return info;
}

- (void)store:(MTPVideoInfo *)info {
    [_memory setObject:info forKey:info.videoID];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:info requiringSecureCoding:YES error:nil];
    [data writeToFile:[self pathFor:info.videoID] atomically:YES];
}

- (void)infoForVideoID:(NSString *)videoID completion:(void (^)(MTPVideoInfo *))completion {
    if (!mtp_is_video_id(videoID.UTF8String)) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    MTPVideoInfo *cached = [self cachedInfoForVideoID:videoID];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    @synchronized (_pending) {
        NSMutableArray *waiters = _pending[videoID];
        if (waiters) { [waiters addObject:[completion copy]]; return; }
        _pending[videoID] = [NSMutableArray arrayWithObject:[completion copy]];
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://www.youtube.com/oembed"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:[@"https://www.youtube.com/watch?v=" stringByAppendingString:videoID]],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
    ];
    [[_session dataTaskWithURL:components.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        MTPVideoInfo *info = nil;
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && status == 200 && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                info = [MTPVideoInfo new];
                info.videoID = videoID;
                info.title = [json[@"title"] isKindOfClass:[NSString class]] ? json[@"title"] : nil;
                info.authorName = [json[@"author_name"] isKindOfClass:[NSString class]] ? json[@"author_name"] : nil;
                info.authorURL = [json[@"author_url"] isKindOfClass:[NSString class]] ? json[@"author_url"] : nil;
                info.thumbnailURL = [json[@"thumbnail_url"] isKindOfClass:[NSString class]] ? json[@"thumbnail_url"] : nil;
            }
        } else if (status == 401 || status == 403 || status == 404) {
            info = [MTPVideoInfo new];
            info.videoID = videoID;
            info.unavailable = YES;
        }
        if (info) [self store:info];
        NSArray *waiters;
        @synchronized (self->_pending) {
            waiters = self->_pending[videoID];
            [self->_pending removeObjectForKey:videoID];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^waiter)(MTPVideoInfo *) in waiters) waiter(info);
        });
    }] resume];
}

@end
