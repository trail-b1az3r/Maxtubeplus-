#import "MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Public metadata for a video, retrieved from YouTube's oEmbed endpoint
/// (https://www.youtube.com/oembed). No API key or account access needed.
@interface MTPVideoInfo : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *authorName;
@property (nonatomic, copy, nullable) NSString *authorURL;
@property (nonatomic, copy, nullable) NSString *thumbnailURL;
@property (nonatomic) BOOL unavailable; // private/deleted/not embeddable
@end

@interface MTPVideoInfoProvider : NSObject
+ (instancetype)shared;
/// Synchronous cache lookup (memory + disk).
- (nullable MTPVideoInfo *)cachedInfoForVideoID:(NSString *)videoID;
/// Fetches (or returns cached) info. Completion runs on the main queue.
- (void)infoForVideoID:(NSString *)videoID completion:(void (^)(MTPVideoInfo *_Nullable info))completion;
@end

NS_ASSUME_NONNULL_END
