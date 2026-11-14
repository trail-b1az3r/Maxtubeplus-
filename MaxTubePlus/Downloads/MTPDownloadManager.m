#import "MTPDownloadManager.h"
#import "../Common/MTPVideoInfo.h"
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>

NSNotificationName const MTPDownloadsChangedNotification = @"MTPDownloadsChangedNotification";

static id Get(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static id KVC(id target, NSString *key) {
    if (!target) return nil;
    @try { return [target valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

#pragma mark - Model

@implementation MTPDownloadPart
- (NSDictionary *)dictionary {
    NSMutableDictionary *d = [@{@"kind": _kind, @"url": _url, @"expected": @(_expectedBytes), @"received": @(_receivedBytes), @"finished": @(_finished)} mutableCopy];
    if (_mimeType) d[@"mime"] = _mimeType;
    if (_localPath) d[@"local"] = _localPath;
    if (_resumeDataPath) d[@"resume"] = _resumeDataPath;
    return d;
}
+ (instancetype)partWithDictionary:(NSDictionary *)d {
    MTPDownloadPart *p = [self new];
    p.kind = d[@"kind"] ?: @"video";
    p.url = d[@"url"] ?: @"";
    p.mimeType = d[@"mime"];
    p.expectedBytes = [d[@"expected"] longLongValue];
    p.receivedBytes = [d[@"received"] longLongValue];
    p.localPath = d[@"local"];
    p.resumeDataPath = d[@"resume"];
    p.finished = [d[@"finished"] boolValue];
    return p;
}
@end

@implementation MTPDownloadItem
- (double)progress {
    if (_state == MTPDownloadStateCompleted) return 1;
    long long expected = 0, received = 0;
    for (MTPDownloadPart *p in _parts) { expected += MAX(p.expectedBytes, p.receivedBytes); received += p.receivedBytes; }
    return expected > 0 ? (double)received / (double)expected : 0;
}
- (NSString *)stateDescription {
    switch (_state) {
        case MTPDownloadStateQueued: return _nextRetryAt ? @"Waiting to retry" : @"Queued";
        case MTPDownloadStateDownloading: return [NSString stringWithFormat:@"Downloading %.0f%%", self.progress * 100];
        case MTPDownloadStatePaused: return [NSString stringWithFormat:@"Paused at %.0f%%", self.progress * 100];
        case MTPDownloadStateProcessing: return @"Merging audio and video…";
        case MTPDownloadStateCompleted: return @"Completed";
        case MTPDownloadStateFailed: return [@"Failed: " stringByAppendingString:_errorMessage ?: @"unknown error"];
        case MTPDownloadStateCancelled: return @"Cancelled";
    }
    return @"";
}
- (NSDictionary *)dictionary {
    NSMutableArray *parts = [NSMutableArray array];
    for (MTPDownloadPart *p in _parts) [parts addObject:[p dictionary]];
    NSMutableDictionary *d = [@{@"id": _identifier, @"video": _videoID, @"title": _title, @"audioOnly": @(_audioOnly), @"quality": _qualityLabel ?: @"",
                                @"state": @(_state), @"parts": parts, @"attempts": @(_attempts), @"created": _createdAt} mutableCopy];
    if (_channel) d[@"channel"] = _channel;
    if (_errorMessage) d[@"error"] = _errorMessage;
    if (_outputPath) d[@"output"] = _outputPath;
    if (_nextRetryAt) d[@"retryAt"] = _nextRetryAt;
    return d;
}
+ (instancetype)itemWithDictionary:(NSDictionary *)d {
    if (![d[@"id"] isKindOfClass:[NSString class]]) return nil;
    MTPDownloadItem *item = [self new];
    item.identifier = d[@"id"];
    item.videoID = d[@"video"] ?: @"";
    item.title = d[@"title"] ?: item.videoID;
    item.channel = d[@"channel"];
    item.audioOnly = [d[@"audioOnly"] boolValue];
    item.qualityLabel = d[@"quality"] ?: @"";
    item.state = [d[@"state"] integerValue];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *p in d[@"parts"] ?: @[]) [parts addObject:[MTPDownloadPart partWithDictionary:p]];
    item.parts = parts;
    item.attempts = [d[@"attempts"] integerValue];
    item.errorMessage = d[@"error"];
    item.outputPath = d[@"output"];
    item.createdAt = d[@"created"] ?: [NSDate date];
    item.nextRetryAt = d[@"retryAt"];
    return item;
}
@end

#pragma mark - Manager

@interface MTPDownloadManager () <NSURLSessionDownloadDelegate>
@end

@implementation MTPDownloadManager {
    NSMutableArray<MTPDownloadItem *> *_items;
    NSURLSession *_session;
    NSMutableDictionary<NSString *, NSURLSessionDownloadTask *> *_tasks; // "itemID|kind"
    NSString *_statePath;
    NSString *_partsDirectory;
    dispatch_queue_t _queue;
    NSTimeInterval _lastPersist;
}

+ (NSString *)sessionIdentifier { return @"com.maxtubeplus.downloads.background"; }

+ (NSString *)downloadsDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [documents stringByAppendingPathComponent:@"MaxTubePlus Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

+ (instancetype)shared {
    static MTPDownloadManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.maxtubeplus.downloads", DISPATCH_QUEUE_SERIAL);
        _tasks = [NSMutableDictionary dictionary];
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [support stringByAppendingPathComponent:@"MaxTubePlus/Downloads"];
        _partsDirectory = [directory stringByAppendingPathComponent:@"Parts"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_partsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        _statePath = [directory stringByAppendingPathComponent:@"Queue.plist"];
        _items = [NSMutableArray array];
        for (NSDictionary *d in [NSArray arrayWithContentsOfFile:_statePath] ?: @[]) {
            MTPDownloadItem *item = [MTPDownloadItem itemWithDictionary:d];
            if (item) [_items addObject:item];
        }
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[MTPDownloadManager sessionIdentifier]];
        config.sessionSendsLaunchEvents = YES;
        config.discretionary = NO;
        config.allowsCellularAccess = [MTPPrefs boolForKey:MTPKeyDownloadsCellular];
        config.HTTPMaximumConnectionsPerHost = MAX(1, [MTPPrefs integerForKey:MTPKeyDownloadsMaxConcurrent]) * 2;
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.underlyingQueue = _queue;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];
    }
    return self;
}

- (NSArray<MTPDownloadItem *> *)items {
    __block NSArray *copy;
    dispatch_sync(_queue, ^{ copy = [self->_items copy]; });
    return copy;
}

- (void)persistForce:(BOOL)force {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - _lastPersist < 1.0) { [self notify]; return; }
    _lastPersist = now;
    NSMutableArray *array = [NSMutableArray array];
    for (MTPDownloadItem *item in _items) [array addObject:[item dictionary]];
    [array writeToFile:_statePath atomically:YES];
    [self notify];
}

- (void)notify {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MTPDownloadsChangedNotification object:self];
    });
}

#pragma mark Enqueue

static NSDictionary *DescribeFormat(id format) {
    NSString *url = KVC(format, @"URL") ?: KVC(format, @"url");
    NSString *mime = KVC(format, @"mimeType");
    if (![url isKindOfClass:[NSString class]] || ![mime isKindOfClass:[NSString class]]) return nil;
    NSMutableDictionary *d = [@{@"url": url, @"mime": mime} mutableCopy];
    d[@"height"] = KVC(format, @"height") ?: @0;
    d[@"bitrate"] = KVC(format, @"bitrate") ?: @0;
    d[@"length"] = KVC(format, @"contentLength") ?: @0;
    d[@"label"] = KVC(format, @"qualityLabel") ?: @"";
    return d;
}

- (NSString *)enqueueFromPlayer:(id)player {
    id controller = Get(player, @"activeVideo");
    id singleVideo = Get(controller, @"singleVideo") ?: Get(controller, @"videoData");
    NSString *videoID = Get(singleVideo, @"videoId") ?: Get(player, @"contentVideoID");
    // 21.45.4: YTSingleVideo -playbackData -> YTPlaybackData -video (MLVideo);
    // older builds: YTSingleVideo -video. Last resort: the raw player response.
    id playbackData = Get(singleVideo, @"playbackData");
    id mlVideo = Get(playbackData, @"video") ?: Get(singleVideo, @"video");
    id streaming = Get(Get(mlVideo, @"streamingData"), @"streamingData");
    if (!streaming) streaming = Get(Get(Get(playbackData, @"playerResponse"), @"playerData"), @"streamingData");
    NSArray *formats = Get(streaming, @"adaptiveFormatsArray");
    if (![videoID isKindOfClass:[NSString class]] || !mtp_is_video_id(videoID.UTF8String)) return @"No video is playing.";
    if (![formats isKindOfClass:[NSArray class]] || formats.count == 0) return @"YouTube did not expose streaming formats for this video (live, premium-only or changed API).";

    // AVFoundation can only mux MP4 (H.264 + AAC); WebM/VP9/AV1/Opus are skipped.
    NSMutableArray<NSDictionary *> *videos = [NSMutableArray array], *audios = [NSMutableArray array];
    for (id format in formats) {
        NSDictionary *d = DescribeFormat(format);
        NSString *mime = d[@"mime"];
        if (!mime) continue;
        if ([mime hasPrefix:@"video/mp4"] && [mime containsString:@"avc1"]) [videos addObject:d];
        else if ([mime hasPrefix:@"audio/mp4"]) [audios addObject:d];
    }
    BOOL audioOnly = [MTPPrefs boolForKey:MTPKeyDownloadsAudioOnly];
    NSInteger maxHeight = [MTPPrefs integerForKey:MTPKeyDownloadsQuality];

    size_t count = videos.count + audios.count;
    int *heights = calloc(MAX(count, 1), sizeof(int));
    bool *isAudio = calloc(MAX(count, 1), sizeof(bool));
    long *bitrates = calloc(MAX(count, 1), sizeof(long));
    NSArray *all = [videos arrayByAddingObjectsFromArray:audios];
    for (size_t i = 0; i < count; i++) {
        heights[i] = [all[i][@"height"] intValue];
        isAudio[i] = i >= videos.count;
        bitrates[i] = [all[i][@"bitrate"] longValue];
    }
    long videoIndex = audioOnly ? -1 : mtp_pick_format(heights, isAudio, bitrates, count, (int)maxHeight, false);
    long audioIndex = mtp_pick_format(heights, isAudio, bitrates, count, 0, true);
    free(heights); free(isAudio); free(bitrates);
    if (audioIndex < 0) return @"No AAC audio stream available for this video.";
    if (!audioOnly && videoIndex < 0) return @"No H.264 MP4 video stream available for this video.";

    MTPDownloadItem *item = [MTPDownloadItem new];
    item.identifier = [NSUUID UUID].UUIDString;
    item.videoID = videoID;
    item.title = videoID;
    item.audioOnly = audioOnly;
    item.createdAt = [NSDate date];
    item.state = MTPDownloadStateQueued;
    NSMutableArray *parts = [NSMutableArray array];
    if (videoIndex >= 0) {
        MTPDownloadPart *part = [MTPDownloadPart new];
        part.kind = @"video";
        part.url = all[videoIndex][@"url"];
        part.mimeType = all[videoIndex][@"mime"];
        part.expectedBytes = [all[videoIndex][@"length"] longLongValue];
        item.qualityLabel = all[videoIndex][@"label"];
        [parts addObject:part];
    } else {
        item.qualityLabel = @"Audio";
    }
    MTPDownloadPart *audio = [MTPDownloadPart new];
    audio.kind = @"audio";
    audio.url = all[audioIndex][@"url"];
    audio.mimeType = all[audioIndex][@"mime"];
    audio.expectedBytes = [all[audioIndex][@"length"] longLongValue];
    [parts addObject:audio];
    item.parts = parts;

    dispatch_async(_queue, ^{
        [self->_items insertObject:item atIndex:0];
        [self persistForce:YES];
        [self pump];
    });
    [[MTPVideoInfoProvider shared] infoForVideoID:videoID completion:^(MTPVideoInfo *info) {
        if (!info.title) return;
        dispatch_async(self->_queue, ^{
            item.title = info.title;
            item.channel = info.authorName;
            [self persistForce:YES];
        });
    }];
    [self requestNotificationPermission];
    return nil;
}

#pragma mark Scheduling (runs on _queue)

- (NSString *)taskKey:(MTPDownloadItem *)item part:(MTPDownloadPart *)part {
    return [NSString stringWithFormat:@"%@|%@", item.identifier, part.kind];
}

- (void)pump {
    NSInteger limit = MAX(1, [MTPPrefs integerForKey:MTPKeyDownloadsMaxConcurrent]);
    NSInteger active = 0;
    for (MTPDownloadItem *item in _items) if (item.state == MTPDownloadStateDownloading) active++;
    for (MTPDownloadItem *item in [_items reverseObjectEnumerator]) { // oldest first
        if (active >= limit) break;
        if (item.state != MTPDownloadStateQueued) continue;
        if (item.nextRetryAt && [item.nextRetryAt timeIntervalSinceNow] > 0) continue;
        item.nextRetryAt = nil;
        item.state = MTPDownloadStateDownloading;
        item.errorMessage = nil;
        active++;
        for (MTPDownloadPart *part in item.parts) if (!part.finished) [self startPart:part ofItem:item];
    }
    [self persistForce:YES];
}

- (void)startPart:(MTPDownloadPart *)part ofItem:(MTPDownloadItem *)item {
    NSString *key = [self taskKey:item part:part];
    if (_tasks[key]) return;
    NSURLSessionDownloadTask *task = nil;
    if (part.resumeDataPath) {
        NSData *resume = [NSData dataWithContentsOfFile:part.resumeDataPath];
        if (resume) task = [_session downloadTaskWithResumeData:resume];
        [[NSFileManager defaultManager] removeItemAtPath:part.resumeDataPath error:nil];
        part.resumeDataPath = nil;
    }
    if (!task) {
        NSURL *url = [NSURL URLWithString:part.url];
        if (!url) { [self fail:item message:@"Invalid stream URL"]; return; }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        // iOS client stream URLs are served without throttling to the YouTube
        // app's user agent family; keep the app's default UA.
        task = [_session downloadTaskWithRequest:request];
        part.receivedBytes = 0;
    }
    task.taskDescription = key;
    _tasks[key] = task;
    [task resume];
}

- (MTPDownloadItem *)itemForKey:(NSString *)key part:(MTPDownloadPart **)partOut {
    NSArray *components = [key componentsSeparatedByString:@"|"];
    if (components.count != 2) return nil;
    for (MTPDownloadItem *item in _items) {
        if (![item.identifier isEqualToString:components[0]]) continue;
        for (MTPDownloadPart *part in item.parts) if ([part.kind isEqualToString:components[1]]) { if (partOut) *partOut = part; return item; }
    }
    return nil;
}

- (void)fail:(MTPDownloadItem *)item message:(NSString *)message {
    for (MTPDownloadPart *part in item.parts) {
        NSString *key = [self taskKey:item part:part];
        [_tasks[key] cancel];
        [_tasks removeObjectForKey:key];
    }
    item.attempts++;
    NSInteger maxRetries = [MTPPrefs integerForKey:MTPKeyDownloadsMaxRetries];
    BOOL expired = [message containsString:@"403"];
    if (!expired && item.attempts <= maxRetries) {
        double delay = mtp_retry_delay((int)item.attempts - 1, 5, 300);
        item.state = MTPDownloadStateQueued;
        item.nextRetryAt = [NSDate dateWithTimeIntervalSinceNow:delay];
        item.errorMessage = message;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{ [self pump]; });
    } else {
        item.state = MTPDownloadStateFailed;
        item.errorMessage = expired ? @"Stream link expired (HTTP 403). Open the video again and tap Retry." : message;
        [self postNotificationTitle:@"Download failed" body:[NSString stringWithFormat:@"%@ — %@", item.title, item.errorMessage]];
    }
    [self persistForce:YES];
    [self pump];
}

#pragma mark Public controls

- (void)pause:(MTPDownloadItem *)item {
    dispatch_async(_queue, ^{
        if (item.state != MTPDownloadStateDownloading && item.state != MTPDownloadStateQueued) return;
        item.state = MTPDownloadStatePaused;
        for (MTPDownloadPart *part in item.parts) {
            NSString *key = [self taskKey:item part:part];
            NSURLSessionDownloadTask *task = self->_tasks[key];
            if (!task) continue;
            [self->_tasks removeObjectForKey:key];
            [task cancelByProducingResumeData:^(NSData *resumeData) {
                dispatch_async(self->_queue, ^{
                    if (resumeData) {
                        NSString *path = [self->_partsDirectory stringByAppendingPathComponent:[key stringByReplacingOccurrencesOfString:@"|" withString:@"-"]];
                        path = [path stringByAppendingPathExtension:@"resume"];
                        [resumeData writeToFile:path atomically:YES];
                        part.resumeDataPath = path;
                    }
                    [self persistForce:YES];
                });
            }];
        }
        [self persistForce:YES];
        [self pump];
    });
}

- (void)resume:(MTPDownloadItem *)item {
    dispatch_async(_queue, ^{
        if (item.state != MTPDownloadStatePaused) return;
        item.state = MTPDownloadStateQueued;
        item.nextRetryAt = nil;
        [self pump];
    });
}

- (void)cancel:(MTPDownloadItem *)item {
    dispatch_async(_queue, ^{
        for (MTPDownloadPart *part in item.parts) {
            NSString *key = [self taskKey:item part:part];
            [self->_tasks[key] cancel];
            [self->_tasks removeObjectForKey:key];
            [self cleanupPart:part];
        }
        item.state = MTPDownloadStateCancelled;
        [self persistForce:YES];
        [self pump];
    });
}

- (void)retry:(MTPDownloadItem *)item {
    dispatch_async(self->_queue, ^{
        if (item.state != MTPDownloadStateFailed && item.state != MTPDownloadStateCancelled) return;
        item.attempts = 0;
        item.state = MTPDownloadStateQueued;
        item.nextRetryAt = nil;
        item.errorMessage = nil;
        [self pump];
    });
}

- (void)cleanupPart:(MTPDownloadPart *)part {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (part.localPath) [fm removeItemAtPath:part.localPath error:nil];
    if (part.resumeDataPath) [fm removeItemAtPath:part.resumeDataPath error:nil];
    part.localPath = nil;
    part.resumeDataPath = nil;
    part.finished = NO;
    part.receivedBytes = 0;
}

- (void)remove:(MTPDownloadItem *)item deleteFile:(BOOL)deleteFile {
    dispatch_async(_queue, ^{
        for (MTPDownloadPart *part in item.parts) {
            NSString *key = [self taskKey:item part:part];
            [self->_tasks[key] cancel];
            [self->_tasks removeObjectForKey:key];
            [self cleanupPart:part];
        }
        if (deleteFile && item.outputPath) [[NSFileManager defaultManager] removeItemAtPath:item.outputPath error:nil];
        [self->_items removeObject:item];
        [self persistForce:YES];
        [self pump];
    });
}

- (void)removeAllFinished {
    dispatch_async(_queue, ^{
        NSIndexSet *finished = [self->_items indexesOfObjectsPassingTest:^BOOL(MTPDownloadItem *item, NSUInteger idx, BOOL *stop) {
            return item.state == MTPDownloadStateCompleted || item.state == MTPDownloadStateCancelled || item.state == MTPDownloadStateFailed;
        }];
        for (MTPDownloadItem *item in [self->_items objectsAtIndexes:finished]) for (MTPDownloadPart *p in item.parts) [self cleanupPart:p];
        [self->_items removeObjectsAtIndexes:finished]; // completed files stay in the downloads folder
        [self persistForce:YES];
    });
}

- (long long)storageUsedBytes {
    long long total = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[[MTPDownloadManager downloadsDirectory], _partsDirectory]) {
        for (NSString *file in [fm subpathsOfDirectoryAtPath:dir error:nil]) {
            total += [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:file] error:nil] fileSize];
        }
    }
    return total;
}

/// Interrupted-download recovery: match persisted items with the tasks the
/// background session still owns (it survives app termination), and requeue
/// anything whose task is gone.
- (void)reconcileAfterLaunch {
    [_session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        dispatch_async(self->_queue, ^{
            NSMutableSet *live = [NSMutableSet set];
            for (NSURLSessionTask *task in tasks) {
                if (!task.taskDescription || ![task isKindOfClass:[NSURLSessionDownloadTask class]]) continue;
                MTPDownloadPart *part = nil;
                MTPDownloadItem *item = [self itemForKey:task.taskDescription part:&part];
                if (!item || item.state != MTPDownloadStateDownloading) { [task cancel]; continue; }
                self->_tasks[task.taskDescription] = (NSURLSessionDownloadTask *)task;
                [live addObject:task.taskDescription];
            }
            NSUInteger recovered = 0;
            for (MTPDownloadItem *item in self->_items) {
                if (item.state == MTPDownloadStateProcessing) { [self muxItem:item]; continue; }
                if (item.state != MTPDownloadStateDownloading) continue;
                BOOL missing = NO;
                for (MTPDownloadPart *part in item.parts) if (!part.finished && ![live containsObject:[self taskKey:item part:part]]) missing = YES;
                if (missing) {
                    for (MTPDownloadPart *part in item.parts) [self->_tasks removeObjectForKey:[self taskKey:item part:part]];
                    item.state = MTPDownloadStateQueued;
                    recovered++;
                }
            }
            if (recovered) MTPLog(@"downloads: recovered %lu interrupted download(s)", (unsigned long)recovered);
            [self pump];
        });
    }];
}

#pragma mark NSURLSession delegate (on _queue)

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    MTPDownloadPart *part = nil;
    if (![self itemForKey:task.taskDescription part:&part]) return;
    part.receivedBytes = total;
    if (expected > 0) part.expectedBytes = expected;
    [self persistForce:NO];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didResumeAtOffset:(int64_t)offset expectedTotalBytes:(int64_t)expected {
    MTPDownloadPart *part = nil;
    if (![self itemForKey:task.taskDescription part:&part]) return;
    part.receivedBytes = offset;
    if (expected > 0) part.expectedBytes = expected;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    MTPDownloadPart *part = nil;
    MTPDownloadItem *item = [self itemForKey:task.taskDescription part:&part];
    if (!item) return;
    NSInteger status = [(NSHTTPURLResponse *)task.response statusCode];
    if (status >= 400) return; // reported in didCompleteWithError
    NSString *ext = [part.kind isEqualToString:@"audio"] ? @"m4a" : @"mp4";
    NSString *destination = [[_partsDirectory stringByAppendingPathComponent:[task.taskDescription stringByReplacingOccurrencesOfString:@"|" withString:@"-"]] stringByAppendingPathExtension:ext];
    [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
    NSError *error = nil;
    // Must move synchronously: the temporary file is deleted when this returns.
    if ([[NSFileManager defaultManager] moveItemAtPath:location.path toPath:destination error:&error]) {
        part.localPath = destination;
        part.finished = YES;
        part.receivedBytes = MAX(part.receivedBytes, part.expectedBytes);
    } else {
        MTPLog(@"downloads: move failed %@", error);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    MTPDownloadPart *part = nil;
    MTPDownloadItem *item = [self itemForKey:task.taskDescription part:&part];
    if (task.taskDescription) [_tasks removeObjectForKey:task.taskDescription];
    if (!item) return;
    if (error) {
        if (error.code == NSURLErrorCancelled) {
            // Paused / cancelled by us, or app was force-quit with resume data.
            NSData *resume = error.userInfo[NSURLSessionDownloadTaskResumeData];
            if (resume && item.state == MTPDownloadStateDownloading) {
                NSString *path = [[_partsDirectory stringByAppendingPathComponent:[task.taskDescription stringByReplacingOccurrencesOfString:@"|" withString:@"-"]] stringByAppendingPathExtension:@"resume"];
                [resume writeToFile:path atomically:YES];
                part.resumeDataPath = path;
                item.state = MTPDownloadStateQueued;
                [self pump];
            }
            [self persistForce:YES];
            return;
        }
        NSData *resume = error.userInfo[NSURLSessionDownloadTaskResumeData];
        if (resume) {
            NSString *path = [[_partsDirectory stringByAppendingPathComponent:[task.taskDescription stringByReplacingOccurrencesOfString:@"|" withString:@"-"]] stringByAppendingPathExtension:@"resume"];
            [resume writeToFile:path atomically:YES];
            part.resumeDataPath = path;
        }
        [self fail:item message:error.localizedDescription];
        return;
    }
    NSInteger status = [(NSHTTPURLResponse *)task.response statusCode];
    if (status >= 400 || !part.finished) {
        [self fail:item message:[NSString stringWithFormat:@"HTTP %ld", (long)status]];
        return;
    }
    BOOL allDone = YES;
    for (MTPDownloadPart *p in item.parts) if (!p.finished) allDone = NO;
    if (allDone) [self muxItem:item];
    [self persistForce:YES];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^handler)(void) = self.backgroundCompletionHandler;
        self.backgroundCompletionHandler = nil;
        if (handler) handler();
    });
}

#pragma mark Muxing

- (NSString *)outputPathFor:(MTPDownloadItem *)item extension:(NSString *)ext {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    NSString *safe = [[item.title componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"_"];
    if (safe.length > 120) safe = [safe substringToIndex:120];
    NSString *name = [NSString stringWithFormat:@"%@ [%@]%@.%@", safe, item.videoID, item.audioOnly ? @"" : [@" " stringByAppendingString:item.qualityLabel], ext];
    return [[MTPDownloadManager downloadsDirectory] stringByAppendingPathComponent:name];
}

- (void)muxItem:(MTPDownloadItem *)item {
    item.state = MTPDownloadStateProcessing;
    [self persistForce:YES];
    MTPDownloadPart *video = nil, *audio = nil;
    for (MTPDownloadPart *p in item.parts) { if ([p.kind isEqualToString:@"video"]) video = p; else audio = p; }
    NSFileManager *fm = [NSFileManager defaultManager];

    if (item.audioOnly || !video) {
        NSString *output = [self outputPathFor:item extension:@"m4a"];
        [fm removeItemAtPath:output error:nil];
        if ([fm moveItemAtPath:audio.localPath toPath:output error:nil]) [self complete:item output:output];
        else [self fail:item message:@"Could not save audio file"];
        return;
    }

    AVURLAsset *videoAsset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:video.localPath]];
    AVURLAsset *audioAsset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:audio.localPath]];
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVAssetTrack *vTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *aTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!vTrack || !aTrack) { [self fail:item message:@"Downloaded streams are not readable MP4/AAC"]; return; }
    CMTimeRange range = CMTimeRangeMake(kCMTimeZero, videoAsset.duration);
    NSError *error = nil;
    AVMutableCompositionTrack *cv = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *ca = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    [cv insertTimeRange:range ofTrack:vTrack atTime:kCMTimeZero error:&error];
    if (!error) [ca insertTimeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMinimum(audioAsset.duration, videoAsset.duration)) ofTrack:aTrack atTime:kCMTimeZero error:&error];
    if (error) { [self fail:item message:error.localizedDescription]; return; }
    cv.preferredTransform = vTrack.preferredTransform;

    NSString *output = [self outputPathFor:item extension:@"mp4"];
    [fm removeItemAtPath:output error:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    export.outputURL = [NSURL fileURLWithPath:output];
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;
    // Muxing may run while backgrounded; ask for time to finish.
    __block UIBackgroundTaskIdentifier bg = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"MaxTubePlus mux" expirationHandler:^{
        [export cancelExport];
    }];
    [export exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(self->_queue, ^{
            if (export.status == AVAssetExportSessionStatusCompleted) {
                [self complete:item output:output];
            } else {
                // Keep parts so the user can retry muxing without re-downloading.
                item.state = MTPDownloadStateFailed;
                item.errorMessage = export.error.localizedDescription ?: @"Merging was interrupted";
                for (MTPDownloadPart *p in item.parts) p.finished = p.localPath != nil;
                [self persistForce:YES];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [[UIApplication sharedApplication] endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; });
        });
    }];
}

- (void)complete:(MTPDownloadItem *)item output:(NSString *)output {
    for (MTPDownloadPart *p in item.parts) {
        if (p.localPath) [[NSFileManager defaultManager] removeItemAtPath:p.localPath error:nil];
        p.localPath = nil;
    }
    item.outputPath = output;
    item.state = MTPDownloadStateCompleted;
    item.errorMessage = nil;
    [self persistForce:YES];
    [self postNotificationTitle:@"Download complete" body:item.title];
    [self pump];
}

#pragma mark Notifications

- (void)requestNotificationPermission {
    if (![MTPPrefs boolForKey:MTPKeyDownloadsNotifications]) return;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {}];
}

- (void)postNotificationTitle:(NSString *)title body:(NSString *)body {
    if (![MTPPrefs boolForKey:MTPKeyDownloadsNotifications]) return;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = [@"MaxTubePlus · " stringByAppendingString:title];
    content.body = body ?: @"";
    content.threadIdentifier = @"com.maxtubeplus.downloads";
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

@end
