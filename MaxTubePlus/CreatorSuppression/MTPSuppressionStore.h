#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

@interface MTPCreator : NSObject
@property (nonatomic, copy) NSString *key;              // "UC..." or "name:<display name>"
@property (nonatomic, copy, nullable) NSString *channelID;
@property (nonatomic, copy, nullable) NSString *channelName;
@property (nonatomic) MTPCreatorRecord record;
@property (nonatomic) BOOL manual;                      // suppressed explicitly by the user
- (NSString *)displayName;
@end

extern NSNotificationName const MTPSuppressionChangedNotification;

/// Local, persistent store of negative-feedback history and suppressed creators.
@interface MTPSuppressionStore : NSObject
+ (instancetype)shared;
- (NSArray<MTPCreator *> *)allCreators;
- (NSArray<MTPCreator *> *)suppressedCreators;
- (NSArray<MTPCreator *> *)trackedCreators; // has feedback, not suppressed

/// Records one "Show fewer"/"Don't recommend channel" interaction. Returns the
/// creator if this interaction suppressed it.
- (nullable MTPCreator *)recordNegativeFeedbackForChannelID:(nullable NSString *)channelID name:(nullable NSString *)name;
- (void)suppressManuallyWithChannelID:(nullable NSString *)channelID name:(nullable NSString *)name;
- (void)restoreCreatorWithKey:(NSString *)key;
- (void)forgetCreatorWithKey:(NSString *)key;
- (void)removeAll;

/// True if element bytes reference a suppressed creator (exact protobuf
/// string field match on channel ID or channel name).
- (BOOL)bytesReferenceSuppressedCreator:(NSData *)bytes;
@end

NS_ASSUME_NONNULL_END
