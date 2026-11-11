#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Result of a DeArrow branding lookup for one video.
@interface MTPDeArrowBranding : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *videoID;
/// Community title, already formatted (nil = keep original).
@property (nonatomic, copy, nullable) NSString *title;
/// Timestamp (seconds) of the community thumbnail (nil = keep original).
@property (nonatomic, strong, nullable) NSNumber *thumbnailTime;
@property (nonatomic, strong) NSDate *fetchedAt;
- (nullable NSURL *)thumbnailURL;
@end

/// Native client for the DeArrow API (https://wiki.sponsor.ajay.app/w/API_Docs/DeArrow).
/// Data: DeArrow by Ajay Ramachandran, licensed CC BY-NC-SA 4.0.
@interface MTPDeArrowClient : NSObject
+ (instancetype)shared;
+ (nullable MTPDeArrowBranding *)parseBrandingJSON:(NSData *)data videoID:(NSString *)videoID;
- (nullable MTPDeArrowBranding *)cachedBrandingForVideoID:(NSString *)videoID;
- (void)brandingForVideoID:(NSString *)videoID completion:(nullable void (^)(MTPDeArrowBranding *_Nullable branding))completion;
- (void)clearCache;
@property (nonatomic, readonly) NSUInteger requestCount;
@property (nonatomic, readonly) NSUInteger replacementCount;
@end

NS_ASSUME_NONNULL_END
