#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MTPFilterKind) {
    MTPFilterKindMinLikes,
    MTPFilterKindMinDuration,
    MTPFilterKindMaxDuration,
    MTPFilterKindRecency,
    MTPFilterKindUploadWindow,
};

/// Persistent advanced-search state (filters + sort). Filters are independent:
/// changing the sort mode never clears them.
@interface MTPSearchFilterState : NSObject
+ (instancetype)shared;
@property (nonatomic) long long minLikes;          // -1 = off
@property (nonatomic) long minDuration;            // seconds, -1 = off
@property (nonatomic) long maxDuration;            // seconds, -1 = off
@property (nonatomic) long long maxAge;            // seconds, -1 = off (recency)
@property (nonatomic, strong, nullable) NSDate *uploadedAfter;
@property (nonatomic, strong, nullable) NSDate *uploadedBefore;
@property (nonatomic) MTPSortMode sortMode;

- (MTPSearchFilter)cFilter;
- (BOOL)hasActiveFilters;
- (NSArray<NSNumber *> *)activeKinds;
- (NSString *)descriptionForKind:(MTPFilterKind)kind;
- (void)removeKind:(MTPFilterKind)kind;
- (void)clearAll;
- (void)save;

/// Base64 (URL-escaped, as YouTube serves it) search "params" covering the
/// server-side buckets + sort; nil when nothing server-side applies.
- (nullable NSString *)encodedSearchParams;

/// Facts about a rendered search result, extracted from element bytes.
+ (MTPVideoFacts)factsFromElementBytes:(NSData *)bytes videoID:(NSString *_Nullable *_Nullable)videoID;
@end

/// Like counts from the Return YouTube Dislike API (public, keyless). YouTube
/// search results do not carry like counts, so this is the only practical
/// source; values are RYD's (official likes when available).
@interface MTPLikesProvider : NSObject
+ (instancetype)shared;
- (long long)cachedLikesForVideoID:(NSString *)videoID; // -1 if unknown
- (void)fetchLikesForVideoIDs:(NSArray<NSString *> *)videoIDs completion:(void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
