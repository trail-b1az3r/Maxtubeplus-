#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// One comment the user wrote.
@interface MTPCommentRecord : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *commentID;
@property (nonatomic, strong, nullable) NSDate *date;
@end

/// Local index of the user's comments.
///
/// Why an import: YouTube's iOS InnerTube API exposes no comment-history
/// endpoint, and watch history does not contain videos the user commented on
/// without watching (or after history was paused/cleared). The complete,
/// authoritative export is Google Takeout ("YouTube and YouTube Music" ->
/// "comments"), which MaxTubePlus parses locally. Google's own My Activity page
/// (myactivity.google.com, "YouTube comments") is offered as a link as well.
@interface MTPCommentHistory : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<MTPCommentRecord *> *records;
@property (nonatomic, readonly, nullable) NSDate *lastImport;

/// Parses a Takeout comments file (CSV from current Takeout, or the older
/// my-comments.html). Returns the number of new comments, or -1 on failure.
- (NSInteger)importTakeoutFileAtURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;
/// Exposed for tests/diagnostics.
+ (NSArray<MTPCommentRecord *> *)parseTakeoutCSV:(NSString *)csv;
+ (NSArray<MTPCommentRecord *> *)parseTakeoutHTML:(NSString *)html;

/// Case-insensitive search across comment text and (cached) video title /
/// channel. Empty query returns everything. Sorted per mode.
- (NSArray<MTPCommentRecord *> *)search:(NSString *)query sort:(MTPSortMode)sort;
- (void)removeAll;
@end

NS_ASSUME_NONNULL_END
