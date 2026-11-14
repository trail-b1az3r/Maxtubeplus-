#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, MTPSettingsGroup) {
    MTPSettingsGroupDownloads = 0,
    MTPSettingsGroupDeArrow,
    MTPSettingsGroupRefreshRate,
    MTPSettingsGroupSuppression,
    MTPSettingsGroupSearch,
    MTPSettingsGroupModernUI,
    MTPSettingsGroupGeneral,
    MTPSettingsGroupAbout,
    MTPSettingsGroupCount,
};

/// One MaxTubePlus settings page (pushed from Settings > MaxTubePlus).
@interface MTPSettingsViewController : UITableViewController
- (instancetype)initWithGroup:(MTPSettingsGroup)group;
+ (NSString *)titleForGroup:(MTPSettingsGroup)group;
+ (NSString *)symbolForGroup:(MTPSettingsGroup)group;
@end

/// Fallback dock editor used when YTPlus's own tab editor is not present.
@interface MTPDockEditorViewController : UITableViewController
@end

/// Root page listing all groups (used by the youtube://maxtubeplus link and
/// anywhere YouTube's own settings list is unavailable).
@interface MTPSettingsRootViewController : UITableViewController
+ (void)presentFromTop;
@end
