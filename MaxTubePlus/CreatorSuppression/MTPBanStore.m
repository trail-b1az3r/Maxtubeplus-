#import "MTPBanStore.h"

NSNotificationName const MTPBansChangedNotification = @"MTPBansChangedNotification";

@implementation MTPBannedCreator
- (NSString *)displayName {
    return _name.length ? [NSString stringWithFormat:@"%@ (@%@)", _name, _handle] : [@"@" stringByAppendingString:_handle];
}
@end

@implementation MTPBanStore {
    NSMutableArray<MTPBannedCreator *> *_creators;
    NSString *_path;
    NSURLSession *_session;
    // Precomputed needles (UTF-8): exact IDs, "@handle" tokens, names.
    NSArray<NSData *> *_ids, *_handles, *_names;
    NSUInteger _hidden;
}

+ (instancetype)shared {
    static MTPBanStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [support stringByAppendingPathComponent:@"MaxTubePlus"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        _path = [directory stringByAppendingPathComponent:@"BannedCreators.plist"];
        _creators = [NSMutableArray array];
        for (NSDictionary *d in [NSArray arrayWithContentsOfFile:_path] ?: @[]) {
            if (![d[@"handle"] isKindOfClass:[NSString class]]) continue;
            MTPBannedCreator *c = [MTPBannedCreator new];
            c.handle = d[@"handle"];
            c.channelID = d[@"channelID"];
            c.name = d[@"name"];
            c.addedAt = d[@"added"] ?: [NSDate date];
            [_creators addObject:c];
        }
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 20;
        // Desktop page + consent cookie: the mobile site redirects and the
        // consent interstitial hides the channel metadata.
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            @"Accept-Language": @"en-US,en;q=0.9",
            @"Cookie": @"CONSENT=YES+1; SOCS=CAI",
        };
        _session = [NSURLSession sessionWithConfiguration:config];
        [self rebuild];
        [[NSNotificationCenter defaultCenter] addObserverForName:MTPPrefsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            [self rebuild];
        }];
    }
    return self;
}

- (NSArray<MTPBannedCreator *> *)creators { @synchronized (self) { return [_creators copy]; } }
- (NSUInteger)hiddenCount { return _hidden; }
- (void)noteHidden { _hidden++; }

+ (NSString *)normalizedHandle:(NSString *)input {
    NSString *text = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange at = [text rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound) text = [text substringFromIndex:at.location + 1];
    NSRange slash = [text rangeOfString:@"/"];
    if (slash.location != NSNotFound) text = [text substringToIndex:slash.location];
    NSRange query = [text rangeOfString:@"?"];
    if (query.location != NSNotFound) text = [text substringToIndex:query.location];
    text = text.lowercaseString;
    // YouTube handles: 3-30 chars of letters, digits, "_", "-", "."
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_-."];
    if (text.length < 3 || text.length > 30 || [text rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return text;
}

- (void)persist {
    NSMutableArray *array = [NSMutableArray array];
    for (MTPBannedCreator *c in _creators) {
        NSMutableDictionary *d = [@{@"handle": c.handle, @"added": c.addedAt} mutableCopy];
        if (c.channelID) d[@"channelID"] = c.channelID;
        if (c.name) d[@"name"] = c.name;
        [array addObject:d];
    }
    [array writeToFile:_path atomically:YES];
    [self rebuild];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MTPBansChangedNotification object:self];
    });
}

- (void)rebuild {
    NSMutableArray *ids = [NSMutableArray array], *handles = [NSMutableArray array], *names = [NSMutableArray array];
    @synchronized (self) {
        for (MTPBannedCreator *c in _creators) {
            [handles addObject:[[@"@" stringByAppendingString:c.handle] dataUsingEncoding:NSUTF8StringEncoding]];
            if (c.channelID.length) [ids addObject:[c.channelID dataUsingEncoding:NSUTF8StringEncoding]];
            if (c.name.length >= 2) [names addObject:[c.name dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
    _ids = ids; _handles = handles; _names = names;
}

static NSString *FirstMatch(NSString *html, NSString *pattern) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    return match && match.numberOfRanges > 1 ? [html substringWithRange:[match rangeAtIndex:1]] : nil;
}

static NSString *DecodeEntities(NSString *text) {
    NSDictionary *entities = @{@"&amp;": @"&", @"&quot;": @"\"", @"&#39;": @"'", @"&lt;": @"<", @"&gt;": @">"};
    for (NSString *key in entities) text = [text stringByReplacingOccurrencesOfString:key withString:entities[key]];
    return text;
}

- (void)resolve:(MTPBannedCreator *)creator completion:(void (^)(NSString *error))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.youtube.com/@%@", creator.handle]];
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSString *message = nil;
        NSString *channelID = html ? (FirstMatch(html, @"\"externalId\":\"(UC[0-9A-Za-z_-]{22})\"") ?: FirstMatch(html, @"/channel/(UC[0-9A-Za-z_-]{22})")) : nil;
        NSString *name = html ? FirstMatch(html, @"<meta property=\"og:title\" content=\"([^\"]*)\"") : nil;
        if (status == 404) message = [NSString stringWithFormat:@"@%@ does not exist", creator.handle];
        else if (!channelID) message = error ? error.localizedDescription : [NSString stringWithFormat:@"Couldn't look up @%@ right now; it is still hidden by handle and will be retried.", creator.handle];
        @synchronized (self) {
            if (channelID) creator.channelID = channelID;
            if (name.length) creator.name = DecodeEntities(name);
            creator.resolveError = message;
        }
        [self persist];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(message); });
    }] resume];
}

- (void)banHandle:(NSString *)input completion:(void (^)(NSString *))completion {
    NSString *handle = [MTPBanStore normalizedHandle:input];
    if (!handle) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Enter a YouTube handle like @channelname (3–30 letters, digits, _ - .)."); });
        return;
    }
    MTPBannedCreator *creator = nil;
    @synchronized (self) {
        for (MTPBannedCreator *c in _creators) if ([c.handle isEqualToString:handle]) creator = c;
        if (!creator) {
            creator = [MTPBannedCreator new];
            creator.handle = handle;
            creator.addedAt = [NSDate date];
            [_creators insertObject:creator atIndex:0];
        }
    }
    [self persist]; // hidden by handle immediately, by ID/name once resolved
    [self resolve:creator completion:completion];
}

- (void)unbanHandle:(NSString *)handle {
    @synchronized (self) {
        NSIndexSet *matches = [_creators indexesOfObjectsPassingTest:^BOOL(MTPBannedCreator *c, NSUInteger idx, BOOL *stop) { return [c.handle isEqualToString:handle]; }];
        [_creators removeObjectsAtIndexes:matches];
    }
    [self persist];
}

- (void)retryResolving {
    for (MTPBannedCreator *c in self.creators) if (!c.channelID) [self resolve:c completion:nil];
}

- (BOOL)bytesReferenceBannedCreator:(NSData *)bytes {
    const uint8_t *b = bytes.bytes;
    size_t n = bytes.length;
    for (NSData *needle in _ids) if (mtp_ci_contains(b, n, needle.bytes, needle.length)) return YES;
    for (NSData *needle in _handles) if (mtp_ci_contains_token(b, n, needle.bytes, needle.length)) return YES;
    BOOL loose = [MTPPrefs boolForKey:MTPKeySearchLooseNames];
    for (NSData *needle in _names) {
        if (loose ? mtp_pb_contains_string_field_ci(b, n, needle.bytes, needle.length)
                  : mtp_pb_contains_string_field(b, n, needle.bytes, needle.length)) return YES;
    }
    return NO;
}

- (BOOL)authorIsBannedWithName:(NSString *)name url:(NSString *)url {
    BOOL loose = [MTPPrefs boolForKey:MTPKeySearchLooseNames];
    for (MTPBannedCreator *c in self.creators) {
        if (url.length) {
            NSString *lower = url.lowercaseString;
            if ([lower hasSuffix:[@"/@" stringByAppendingString:c.handle]]) return YES;
            if (c.channelID && [url hasSuffix:c.channelID]) return YES;
        }
        if (name.length && c.name.length) {
            if (loose ? [name caseInsensitiveCompare:c.name] == NSOrderedSame : [name isEqualToString:c.name]) return YES;
        }
    }
    return NO;
}

@end
