#import <UIKit/UIKit.h>

/// Two-thumb slider used for the duration range (minutes, 0 = no bound at
/// the low end, maximumValue = no bound at the high end).
@interface MTPRangeSlider : UIControl
@property (nonatomic) CGFloat minimumValue;
@property (nonatomic) CGFloat maximumValue;
@property (nonatomic) CGFloat lowerValue;
@property (nonatomic) CGFloat upperValue;
@end

/// Advanced search panel: multiple simultaneous filters, individual removal,
/// clear-all, sort mode, and the commented-videos search mode.
@interface MTPSearchFilterViewController : UITableViewController
+ (void)presentFromTop;
@end
