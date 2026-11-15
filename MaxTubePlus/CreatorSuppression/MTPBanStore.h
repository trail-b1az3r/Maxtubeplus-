#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// A creator banned by @handle: all their videos, Shorts and posts are hidden
/// everywhere (Home, Shorts, Search, Subscriptions, Watch next) except their
/// own channel page.
@interface MTPBannedCreator : NSObject
@property (nonatomic, copy) NSString *handle;               // lowercase, without "@"
@property (nonatomic, copy, nullable) NSString *channelID;  // UC…, once resolved
@property (nonatomic, copy, nullable) NSString *name;       // display name, once resolved
@property (nonatomic, strong) NSDate *addedAt;
@property (nonatomic, copy, nullable) NSString *resolveError;
- (NSString *)displayName;
@end

extern NSNotificationName const MTPBansChangedNotification;

@interface MTPBanStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<MTPBannedCreator *> *creators;
@property (nonatomic, readonly) NSUInteger hiddenCount;

/// Normalises "@Handle", "youtube.com/@Handle", "handle" -> "handle".
+ (nullable NSString *)normalizedHandle:(NSString *)input;

/// Adds a handle and resolves its channel ID and name in the background.
/// Completion (main queue) receives an error message or nil.
- (void)banHandle:(NSString *)input completion:(nullable void (^)(NSString *_Nullable error))completion;
- (void)unbanHandle:(NSString *)handle;
- (void)retryResolving;

/// Element bytes (feed/search/post cells) reference a banned creator.
- (BOOL)bytesReferenceBannedCreator:(NSData *)bytes;
/// oEmbed metadata (used for Shorts) belongs to a banned creator.
- (BOOL)authorIsBannedWithName:(nullable NSString *)name url:(nullable NSString *)url;
- (void)noteHidden;
@end

NS_ASSUME_NONNULL_END
