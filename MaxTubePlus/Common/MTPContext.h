#import "MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// What MaxTubePlus could learn about the item a menu sheet was opened for.
@interface MTPItemContext : NSObject
@property (nonatomic, copy, nullable) NSString *videoID;      // from the cell's thumbnail URL
@property (nonatomic, copy, nullable) NSString *channelID;    // when known (player)
@property (nonatomic, copy, nullable) NSString *channelName;  // from cell text / player
@property (nonatomic, copy) NSArray<NSString *> *texts;       // visible strings in the cell
@property (nonatomic) BOOL fromPlayer;                        // item is the playing video
@end

typedef BOOL (^MTPElementFilter)(NSData *bytes, MTPSurface surface);
typedef void (^MTPElementObserver)(NSData *bytes, MTPSurface surface);
typedef void (^MTPSheetDecorator)(id sheetController, MTPItemContext *context);

@interface MTPContext : NSObject
+ (MTPSurface)currentSurface;
+ (NSString *)nameForSurface:(MTPSurface)surface;
/// The visible main player controller (YTPlayerViewController), if any.
+ (nullable id)currentPlayer;
+ (nullable NSString *)currentVideoID;
+ (nullable NSString *)currentChannelID;
/// The YTSectionListViewController that most recently appeared.
+ (nullable UIViewController *)currentSectionList;

/// Filters run on every element's bytes; returning YES hides the element.
+ (void)addElementFilter:(MTPElementFilter)filter;
/// Observers see every element's bytes (prefetching).
+ (void)addElementObserver:(MTPElementObserver)observer;
/// Decorators may add actions to / wrap actions of menu sheets.
+ (void)addSheetDecorator:(MTPSheetDecorator)decorator;

/// Helpers for decorators.
+ (nullable NSString *)titleOfSheetAction:(id)action;
+ (void)wrapHandlerOfSheetAction:(id)action before:(void (^)(void))before;
+ (nullable id)makeSheetActionWithTitle:(NSString *)title iconType:(int)iconType handler:(void (^)(void))handler;
@end

void MTPInstallContext(void);

NS_ASSUME_NONNULL_END
