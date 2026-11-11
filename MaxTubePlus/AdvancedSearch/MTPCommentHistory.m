#import "MTPCommentHistory.h"
#import "../Common/MTPVideoInfo.h"

@implementation MTPCommentRecord
@end

static NSArray<NSArray<NSString *> *> *ParseCSV(NSString *csv) {
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *row = [NSMutableArray array];
    NSMutableString *field = [NSMutableString string];
    BOOL quoted = NO;
    NSUInteger length = csv.length;
    unichar *chars = malloc(sizeof(unichar) * (length + 1));
    [csv getCharacters:chars range:NSMakeRange(0, length)];
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = chars[i];
        if (quoted) {
            if (c == '"') {
                if (i + 1 < length && chars[i + 1] == '"') { [field appendString:@"\""]; i++; }
                else quoted = NO;
            } else {
                [field appendFormat:@"%C", c];
            }
        } else if (c == '"') {
            quoted = YES;
        } else if (c == ',') {
            [row addObject:[field copy]];
            [field setString:@""];
        } else if (c == '\n' || c == '\r') {
            if (c == '\r' && i + 1 < length && chars[i + 1] == '\n') i++;
            [row addObject:[field copy]];
            [field setString:@""];
            if (!(row.count == 1 && [row[0] length] == 0)) [rows addObject:row];
            row = [NSMutableArray array];
        } else {
            [field appendFormat:@"%C", c];
        }
    }
    free(chars);
    if (field.length || row.count) { [row addObject:[field copy]]; [rows addObject:row]; }
    return rows;
}

/// Takeout stores comment text as JSON text runs: {"text":"Hello "},{"text":"world"}
static NSString *TextFromRuns(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"{"]) return trimmed;
    NSData *data = [[NSString stringWithFormat:@"[%@]", trimmed] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *runs = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![runs isKindOfClass:[NSArray class]]) return trimmed;
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *run in runs) {
        if ([run isKindOfClass:[NSDictionary class]] && [run[@"text"] isKindOfClass:[NSString class]]) [text appendString:run[@"text"]];
    }
    return text.length ? text : trimmed;
}

static NSDate *ParseDate(NSString *value) {
    static NSISO8601DateFormatter *iso, *isoFrac;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iso = [NSISO8601DateFormatter new];
        isoFrac = [NSISO8601DateFormatter new];
        isoFrac.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [isoFrac dateFromString:value] ?: [iso dateFromString:value];
}

@implementation MTPCommentHistory {
    NSMutableArray<MTPCommentRecord *> *_records;
    NSString *_path;
}

+ (instancetype)shared {
    static MTPCommentHistory *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [support stringByAppendingPathComponent:@"MaxTubePlus"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        _path = [directory stringByAppendingPathComponent:@"CommentHistory.plist"];
        _records = [NSMutableArray array];
        NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:_path];
        _lastImport = stored[@"lastImport"];
        for (NSDictionary *d in stored[@"records"] ?: @[]) {
            MTPCommentRecord *r = [MTPCommentRecord new];
            r.videoID = d[@"v"];
            r.text = d[@"t"] ?: @"";
            r.commentID = d[@"c"];
            r.date = d[@"d"];
            if (r.videoID) [_records addObject:r];
        }
    }
    return self;
}

- (NSArray<MTPCommentRecord *> *)records { @synchronized (self) { return [_records copy]; } }

- (void)persist {
    NSMutableArray *array = [NSMutableArray array];
    for (MTPCommentRecord *r in _records) {
        NSMutableDictionary *d = [@{@"v": r.videoID, @"t": r.text} mutableCopy];
        if (r.commentID) d[@"c"] = r.commentID;
        if (r.date) d[@"d"] = r.date;
        [array addObject:d];
    }
    NSMutableDictionary *root = [@{@"records": array} mutableCopy];
    if (_lastImport) root[@"lastImport"] = _lastImport;
    [root writeToFile:_path atomically:YES];
}

+ (NSArray<MTPCommentRecord *> *)parseTakeoutCSV:(NSString *)csv {
    NSArray *rows = ParseCSV(csv);
    if (rows.count < 2) return @[];
    NSArray<NSString *> *header = rows[0];
    NSInteger (^column)(NSArray<NSString *> *) = ^NSInteger(NSArray<NSString *> *names) {
        for (NSUInteger i = 0; i < header.count; i++) {
            NSString *h = [header[i] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ﻿"]].lowercaseString;
            for (NSString *name in names) if ([h isEqualToString:name]) return (NSInteger)i;
        }
        return -1;
    };
    NSInteger videoCol = column(@[@"video id", @"video_id"]);
    NSInteger textCol = column(@[@"comment text", @"comment_text", @"text"]);
    NSInteger dateCol = column(@[@"comment create timestamp", @"timestamp", @"created"]);
    NSInteger idCol = column(@[@"comment id", @"comment_id"]);
    if (videoCol < 0 || textCol < 0) return @[];
    NSMutableArray *records = [NSMutableArray array];
    for (NSUInteger i = 1; i < rows.count; i++) {
        NSArray<NSString *> *row = rows[i];
        if ((NSInteger)row.count <= MAX(videoCol, textCol)) continue;
        NSString *videoID = [row[videoCol] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!mtp_is_video_id(videoID.UTF8String)) continue; // community posts etc.
        MTPCommentRecord *r = [MTPCommentRecord new];
        r.videoID = videoID;
        r.text = TextFromRuns(row[textCol]);
        if (dateCol >= 0 && dateCol < (NSInteger)row.count) r.date = ParseDate(row[dateCol]);
        if (idCol >= 0 && idCol < (NSInteger)row.count && [row[idCol] length]) r.commentID = row[idCol];
        [records addObject:r];
    }
    return records;
}

+ (NSArray<MTPCommentRecord *> *)parseTakeoutHTML:(NSString *)html {
    // Older Takeout: each entry links the video ("watch?v=ID&lc=COMMENT") and
    // is followed by the comment text, separated by <br>.
    static NSRegularExpression *entry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        entry = [NSRegularExpression regularExpressionWithPattern:@"watch\\?v=([A-Za-z0-9_-]{11})(?:&amp;|&)lc=([A-Za-z0-9_.-]+)[^>]*>.*?</a>.*?<br\\s*/?>(.*?)(?=<br|</div>|</li>|$)"
                                                          options:NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableArray *records = [NSMutableArray array];
    [entry enumerateMatchesInString:html options:0 range:NSMakeRange(0, html.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        MTPCommentRecord *r = [MTPCommentRecord new];
        r.videoID = [html substringWithRange:[m rangeAtIndex:1]];
        r.commentID = [html substringWithRange:[m rangeAtIndex:2]];
        NSString *raw = [html substringWithRange:[m rangeAtIndex:3]];
        NSAttributedString *decoded = [[NSAttributedString alloc] initWithData:[raw dataUsingEncoding:NSUTF8StringEncoding]
                                                                       options:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType, NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)}
                                                            documentAttributes:nil error:nil];
        r.text = [(decoded.string ?: raw) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [records addObject:r];
    }];
    return records;
}

- (NSInteger)importTakeoutFileAtURL:(NSURL *)url error:(NSError **)error {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *content = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!content) return -1;
    NSArray *parsed = [content rangeOfString:@"<html" options:NSCaseInsensitiveSearch].location != NSNotFound
        ? [MTPCommentHistory parseTakeoutHTML:content]
        : [MTPCommentHistory parseTakeoutCSV:content];
    if (parsed.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"MaxTubePlus" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No YouTube video comments found. Choose comments.csv (or my-comments.html) from the Takeout \"YouTube and YouTube Music\" export."}];
        return -1;
    }
    NSInteger added = 0;
    @synchronized (self) {
        NSMutableSet *existing = [NSMutableSet set];
        for (MTPCommentRecord *r in _records) [existing addObject:r.commentID ?: [r.videoID stringByAppendingString:r.text]];
        for (MTPCommentRecord *r in parsed) {
            NSString *key = r.commentID ?: [r.videoID stringByAppendingString:r.text];
            if ([existing containsObject:key]) continue;
            [existing addObject:key];
            [_records addObject:r];
            added++;
        }
        _lastImport = [NSDate date];
        [self persist];
    }
    return added;
}

- (NSArray<MTPCommentRecord *> *)search:(NSString *)query sort:(MTPSortMode)sort {
    NSArray *all = self.records;
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray<NSString *> *terms = q.length ? [q.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary<NSValue *, NSNumber *> *scores = [NSMutableDictionary dictionary];
    MTPVideoInfoProvider *info = [MTPVideoInfoProvider shared];
    for (MTPCommentRecord *r in all) {
        if (terms.count == 0) { [matches addObject:r]; continue; }
        MTPVideoInfo *video = [info cachedInfoForVideoID:r.videoID];
        NSString *haystack = [NSString stringWithFormat:@"%@\n%@\n%@", r.text, video.title ?: @"", video.authorName ?: @""].lowercaseString;
        NSInteger score = 0;
        BOOL matchesAll = YES;
        for (NSString *term in terms) {
            if (!term.length) continue;
            NSRange range = [haystack rangeOfString:term];
            if (range.location == NSNotFound) { matchesAll = NO; break; }
            score += [r.text.lowercaseString containsString:term] ? 3 : 1; // comment text weighs more
        }
        if (!matchesAll) continue;
        scores[[NSValue valueWithNonretainedObject:r]] = @(score);
        [matches addObject:r];
    }
    [matches sortUsingComparator:^NSComparisonResult(MTPCommentRecord *a, MTPCommentRecord *b) {
        if (sort == MTPSortRelevance && terms.count) {
            NSInteger sa = [scores[[NSValue valueWithNonretainedObject:a]] integerValue];
            NSInteger sb = [scores[[NSValue valueWithNonretainedObject:b]] integerValue];
            if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        }
        NSDate *da = a.date ?: [NSDate distantPast], *db = b.date ?: [NSDate distantPast];
        return [db compare:da];
    }];
    return matches;
}

- (void)removeAll {
    @synchronized (self) { [_records removeAllObjects]; _lastImport = nil; [self persist]; }
}

@end
