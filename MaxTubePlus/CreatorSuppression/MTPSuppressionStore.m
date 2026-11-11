#import "MTPSuppressionStore.h"

NSNotificationName const MTPSuppressionChangedNotification = @"MTPSuppressionChangedNotification";

@implementation MTPCreator

- (NSString *)displayName {
    return _channelName.length ? _channelName : (_channelID ?: _key);
}

- (NSDictionary *)dictionary {
    MTPCreatorRecord r = _record;
    NSMutableDictionary *d = [@{
        @"key": _key, @"count": @(r.negativeCount), @"first": @(r.firstEventUnix), @"last": @(r.lastEventUnix),
        @"suppressed": @(r.suppressed), @"restored": @(r.restoredByUser), @"manual": @(_manual),
    } mutableCopy];
    if (_channelID) d[@"channelID"] = _channelID;
    if (_channelName) d[@"channelName"] = _channelName;
    return d;
}

+ (instancetype)creatorWithDictionary:(NSDictionary *)d {
    if (![d[@"key"] isKindOfClass:[NSString class]]) return nil;
    MTPCreator *c = [MTPCreator new];
    c.key = d[@"key"];
    c.channelID = [d[@"channelID"] isKindOfClass:[NSString class]] ? d[@"channelID"] : nil;
    c.channelName = [d[@"channelName"] isKindOfClass:[NSString class]] ? d[@"channelName"] : nil;
    MTPCreatorRecord r = {0};
    r.negativeCount = [d[@"count"] intValue];
    r.firstEventUnix = [d[@"first"] longLongValue];
    r.lastEventUnix = [d[@"last"] longLongValue];
    r.suppressed = [d[@"suppressed"] boolValue];
    r.restoredByUser = [d[@"restored"] boolValue];
    c.record = r;
    c.manual = [d[@"manual"] boolValue];
    return c;
}

@end

@implementation MTPSuppressionStore {
    NSMutableDictionary<NSString *, MTPCreator *> *_creators;
    NSArray<NSData *> *_suppressedNeedles; // UTF-8 channel IDs + names
    NSString *_path;
}

+ (instancetype)shared {
    static MTPSuppressionStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [support stringByAppendingPathComponent:@"MaxTubePlus"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        _path = [directory stringByAppendingPathComponent:@"CreatorSuppression.plist"];
        _creators = [NSMutableDictionary dictionary];
        for (NSDictionary *d in [NSArray arrayWithContentsOfFile:_path] ?: @[]) {
            MTPCreator *c = [MTPCreator creatorWithDictionary:d];
            if (c) _creators[c.key] = c;
        }
        [self rebuildNeedles];
    }
    return self;
}

- (void)persist {
    NSMutableArray *array = [NSMutableArray array];
    for (MTPCreator *c in _creators.allValues) [array addObject:[c dictionary]];
    [array writeToFile:_path atomically:YES];
    [self rebuildNeedles];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MTPSuppressionChangedNotification object:self];
    });
}

- (void)rebuildNeedles {
    NSMutableArray *needles = [NSMutableArray array];
    for (MTPCreator *c in _creators.allValues) {
        if (!c.record.suppressed) continue;
        if (c.channelID.length) [needles addObject:[c.channelID dataUsingEncoding:NSUTF8StringEncoding]];
        // Very short names would match unrelated strings; require 3+ chars.
        if (c.channelName.length >= 3) [needles addObject:[c.channelName dataUsingEncoding:NSUTF8StringEncoding]];
    }
    _suppressedNeedles = needles;
}

static NSString *KeyFor(NSString *channelID, NSString *name) {
    if (channelID.length && mtp_is_channel_id(channelID.UTF8String, channelID.length)) return channelID;
    if (name.length) return [@"name:" stringByAppendingString:name];
    return nil;
}

- (MTPCreator *)creatorForChannelID:(NSString *)channelID name:(NSString *)name create:(BOOL)create {
    // Merge records that were first seen by name and later by ID.
    MTPCreator *byID = channelID.length ? _creators[channelID] : nil;
    MTPCreator *byName = name.length ? _creators[[@"name:" stringByAppendingString:name]] : nil;
    if (!byID && byName && channelID.length && mtp_is_channel_id(channelID.UTF8String, channelID.length)) {
        [_creators removeObjectForKey:byName.key];
        byName.key = channelID;
        byName.channelID = channelID;
        _creators[channelID] = byName;
        byID = byName;
    }
    MTPCreator *creator = byID ?: byName;
    if (!creator && create) {
        NSString *key = KeyFor(channelID, name);
        if (!key) return nil;
        creator = [MTPCreator new];
        creator.key = key;
        _creators[key] = creator;
    }
    if (channelID.length && !creator.channelID) creator.channelID = channelID;
    if (name.length && !creator.channelName) creator.channelName = name;
    return creator;
}

- (MTPSuppressionPolicy)policy {
    MTPSuppressionPolicy p;
    p.threshold = (int)[MTPPrefs integerForKey:MTPKeySuppressionThreshold];
    p.windowSeconds = (long long)[MTPPrefs integerForKey:MTPKeySuppressionWindowDays] * 86400;
    p.autoSuppress = [MTPPrefs boolForKey:MTPKeySuppressionAuto];
    return p;
}

- (MTPCreator *)recordNegativeFeedbackForChannelID:(NSString *)channelID name:(NSString *)name {
    @synchronized (self) {
        MTPCreator *creator = [self creatorForChannelID:channelID name:name create:YES];
        if (!creator) return nil;
        MTPCreatorRecord record = creator.record;
        MTPSuppressionPolicy policy = [self policy];
        BOOL suppressedNow = mtp_record_negative_feedback(&record, &policy, (long long)[NSDate date].timeIntervalSince1970);
        creator.record = record;
        [self persist];
        MTPLog(@"suppression: %@ now %d interaction(s)%@", creator.displayName, record.negativeCount, suppressedNow ? @" -> suppressed" : @"");
        return suppressedNow ? creator : nil;
    }
}

- (void)suppressManuallyWithChannelID:(NSString *)channelID name:(NSString *)name {
    @synchronized (self) {
        MTPCreator *creator = [self creatorForChannelID:channelID name:name create:YES];
        if (!creator) return;
        MTPCreatorRecord record = creator.record;
        record.suppressed = true;
        record.restoredByUser = false;
        record.lastEventUnix = (long long)[NSDate date].timeIntervalSince1970;
        creator.record = record;
        creator.manual = YES;
        [self persist];
    }
}

- (void)restoreCreatorWithKey:(NSString *)key {
    @synchronized (self) {
        MTPCreator *creator = _creators[key];
        if (!creator) return;
        MTPCreatorRecord record = creator.record;
        mtp_restore_creator(&record);
        creator.record = record;
        creator.manual = NO;
        [self persist];
    }
}

- (void)forgetCreatorWithKey:(NSString *)key {
    @synchronized (self) { [_creators removeObjectForKey:key]; [self persist]; }
}

- (void)removeAll {
    @synchronized (self) { [_creators removeAllObjects]; [self persist]; }
}

- (NSArray *)sorted:(BOOL (^)(MTPCreator *))predicate {
    @synchronized (self) {
        NSMutableArray *result = [NSMutableArray array];
        for (MTPCreator *c in _creators.allValues) if (predicate(c)) [result addObject:c];
        [result sortUsingComparator:^NSComparisonResult(MTPCreator *a, MTPCreator *b) {
            return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
        }];
        return result;
    }
}

- (NSArray *)allCreators { return [self sorted:^BOOL(MTPCreator *c) { return YES; }]; }
- (NSArray *)suppressedCreators { return [self sorted:^BOOL(MTPCreator *c) { return c.record.suppressed; }]; }
- (NSArray *)trackedCreators { return [self sorted:^BOOL(MTPCreator *c) { return !c.record.suppressed && c.record.negativeCount > 0; }]; }

- (BOOL)bytesReferenceSuppressedCreator:(NSData *)bytes {
    NSArray *needles = _suppressedNeedles;
    for (NSData *needle in needles) {
        if (mtp_pb_contains_string_field(bytes.bytes, bytes.length, needle.bytes, needle.length)) return YES;
    }
    return NO;
}

@end
