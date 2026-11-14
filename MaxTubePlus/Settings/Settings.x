// Adds a "MaxTubePlus" section to YouTube's own settings (same mechanism as
// YTPlus and PoomSmart's tweaks: a custom category in settingsCategoryOrder
// filled by -[YTSettingsSectionItemManager updateSectionForCategory:withEntry:]).
// Each row opens a native page for one of the eight groups.

#import <objc/runtime.h>
#import <objc/message.h>
#import "MTPSettingsViewController.h"
#import "../Common/MTPCommon.h"
#import "../Common/MTPYouTube.h"

static const NSInteger MTPSettingsCategory = 20260; // unique, outside YouTube/YTPlus/RYD ranges

@interface YTSettingsSectionItemManager (MaxTubePlus)
- (void)updateMaxTubePlusSectionWithEntry:(id)entry;
@end

@interface YTSettingsGroupData : NSObject
@property (nonatomic, readonly, assign) NSUInteger type;
@end

static void PushFromSettings(id delegate, UIViewController *page) {
    if ([delegate respondsToSelector:@selector(pushViewController:)]) {
        [delegate performSelector:@selector(pushViewController:) withObject:page];
    } else if ([delegate isKindOfClass:[UIViewController class]] && [(UIViewController *)delegate navigationController]) {
        [[(UIViewController *)delegate navigationController] pushViewController:page animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        [MTPTopViewController() presentViewController:nav animated:YES completion:nil];
    }
}

static id MakeItem(NSString *title, NSString *subtitle, BOOL (^select)(id cell, NSUInteger arg)) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL full = NSSelectorFromString(@"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (![itemClass respondsToSelector:full]) return nil;
    return ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(itemClass, full, title, subtitle, @"MaxTubePlusSectionItem", nil, select);
}

%group Settings

%hook YTAppSettingsPresentationData
+ (NSArray *)settingsCategoryOrder {
    NSArray *order = %orig;
    if ([order containsObject:@(MTPSettingsCategory)]) return order;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    NSMutableArray *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(MTPSettingsCategory) atIndex:insertIndex == NSNotFound ? 0 : insertIndex + 1];
    return mutableOrder;
}
%end

%end

// Category placement. Current YouTube builds the settings list from groups;
// a category only appears if some group lists it:
//  * MaxTube builds usually include YouGroupSettings, which adds a "Tweaks"
//    group backed by the mutable array +[YTSettingsGroupData tweaks]. Tweaks
//    must add their category ID to that array (YTPlus/RYD are pre-listed).
//  * Without it, the category is added to YouTube's first group (type 1) via
//    -orderedCategoriesForGroupType: (current) and -orderedCategories (older).
static BOOL RegisterWithYouGroupSettings(void) {
    Class groupData = objc_getClass("YTSettingsGroupData");
    SEL tweaksSel = NSSelectorFromString(@"tweaks");
    if (!groupData || !class_getClassMethod(groupData, tweaksSel)) return NO;
    NSMutableArray *tweaks = ((id (*)(id, SEL))objc_msgSend)(groupData, tweaksSel);
    if (![tweaks isKindOfClass:[NSMutableArray class]]) return NO;
    @synchronized (tweaks) {
        if (![tweaks containsObject:@(MTPSettingsCategory)]) [tweaks insertObject:@(MTPSettingsCategory) atIndex:0];
    }
    return YES;
}

static NSArray *AddCategory(NSArray *categories, NSUInteger groupType) {
    if (RegisterWithYouGroupSettings()) return categories; // YouGroupSettings lists it
    if (groupType != 1 || ![categories isKindOfClass:[NSArray class]] || [categories containsObject:@(MTPSettingsCategory)]) return categories;
    NSMutableArray *mutableCategories = [categories mutableCopy];
    [mutableCategories insertObject:@(MTPSettingsCategory) atIndex:0];
    return mutableCategories;
}

%group SettingsGroupsByType
%hook YTSettingsGroupData
- (NSArray *)orderedCategoriesForGroupType:(NSUInteger)type {
    return AddCategory(%orig, type);
}
%end
%end

%group SettingsGroupsLegacy
%hook YTSettingsGroupData
- (NSArray *)orderedCategories {
    NSArray *categories = %orig;
    NSUInteger type = [self respondsToSelector:@selector(type)] ? (NSUInteger)self.type : 0;
    return AddCategory(categories, type);
}
%end
%end

%group SettingsItems

%hook YTSettingsSectionItemManager
%new(v@:@)
- (void)updateMaxTubePlusSectionWithEntry:(id)entry {
    id delegate = nil;
    @try { delegate = [self valueForKey:@"_dataDelegate"]; } @catch (__unused NSException *e) {}
    NSMutableArray *items = [NSMutableArray array];
    MTPCompat *compat = [MTPCompat shared];
    extern BOOL MTPSafeModeActive(void);
    NSString *statusLine = MTPSafeModeActive() ? @"SAFE MODE — features off after a startup crash. Open General to re-enable." : [NSString stringWithFormat:@"YouTube %@ · %@", compat.appVersion,
                            compat.level == MTPCompatVerified ? @"verified" : (compat.level == MTPCompatSameMajor ? @"compatible (guarded)" : @"unverified — modules off")];
    id header = MakeItem([NSString stringWithFormat:@"MaxTubePlus %s", MTP_VERSION], statusLine, ^BOOL(id cell, NSUInteger arg) {
        PushFromSettings(delegate, [[MTPSettingsViewController alloc] initWithGroup:MTPSettingsGroupAbout]);
        return YES;
    });
    if (header) [items addObject:header];
    for (NSInteger group = 0; group < MTPSettingsGroupCount; group++) {
        id item = MakeItem([MTPSettingsViewController titleForGroup:group], nil, ^BOOL(id cell, NSUInteger arg) {
            PushFromSettings(delegate, [[MTPSettingsViewController alloc] initWithGroup:group]);
            return YES;
        });
        if (item) [items addObject:item];
    }
    SEL withIcon = NSSelectorFromString(@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL plain = NSSelectorFromString(@"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if ([delegate respondsToSelector:withIcon]) {
        id icon = [NSClassFromString(@"YTIIcon") new];
        SEL setType = NSSelectorFromString(@"setIconType:");
        if ([icon respondsToSelector:setType]) ((void (*)(id, SEL, int))objc_msgSend)(icon, setType, 44); // YT_SETTINGS
        ((void (*)(id, SEL, id, NSInteger, id, id, id, BOOL))objc_msgSend)(delegate, withIcon, items, MTPSettingsCategory, @"MaxTubePlus", icon, nil, NO);
    } else if ([delegate respondsToSelector:plain]) {
        ((void (*)(id, SEL, id, NSInteger, id, id, BOOL))objc_msgSend)(delegate, plain, items, MTPSettingsCategory, @"MaxTubePlus", nil, NO);
    } else {
        MTPLog(@"settings: YTSettingsViewController API not found");
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == MTPSettingsCategory) {
        [self updateMaxTubePlusSectionWithEntry:entry];
        return;
    }
    %orig;
}
%end

%end

void MTPInstallSettings(void) {
    MTPCompat *compat = [MTPCompat shared];
    BOOL ok = NSClassFromString(@"YTAppSettingsPresentationData") && MTPClassWithSelectors(@"YTSettingsSectionItemManager", @[@"updateSectionForCategory:withEntry:"]);
    if (!ok) {
        [compat setStatus:@"YouTube settings API not found" forModule:MTPModuleSettings];
        return;
    }
    %init(Settings);
    %init(SettingsItems);
    NSMutableArray *paths = [NSMutableArray array];
    if (MTPClassWithSelectors(@"YTSettingsGroupData", @[@"orderedCategoriesForGroupType:"])) { %init(SettingsGroupsByType); [paths addObject:@"groups"]; }
    if (MTPClassWithSelectors(@"YTSettingsGroupData", @[@"orderedCategories"])) { %init(SettingsGroupsLegacy); [paths addObject:@"legacy groups"]; }
    // YouGroupSettings may load after MaxTubePlus; register again once launched.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        BOOL ygs = RegisterWithYouGroupSettings();
        [compat setStatus:[NSString stringWithFormat:@"Section registered (%@%@); also youtube://maxtubeplus", [paths componentsJoinedByString:@", "], ygs ? @", YouGroupSettings Tweaks group" : @""] forModule:MTPModuleSettings];
    }];
    extern void MTPRegisterSettingsURL(void);
    MTPRegisterSettingsURL();
    [compat setStatus:[NSString stringWithFormat:@"Section registered (%@)", [paths componentsJoinedByString:@", "]] forModule:MTPModuleSettings];
}
