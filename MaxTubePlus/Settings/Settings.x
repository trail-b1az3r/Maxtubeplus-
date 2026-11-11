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
@property (nonatomic, assign) NSInteger type;
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

%group SettingsGroups
%hook YTSettingsGroupData
- (NSArray *)orderedCategories {
    // YouTube 19.x+ grouped settings: add to the tweak group (type 1) once.
    NSArray *categories = %orig;
    if (self.type != 1 || [categories containsObject:@(MTPSettingsCategory)] || class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks))) return categories;
    NSMutableArray *mutableCategories = [categories mutableCopy];
    [mutableCategories insertObject:@(MTPSettingsCategory) atIndex:0];
    return mutableCategories;
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
        ((void (*)(id, SEL, id, NSInteger, id, id, id, BOOL))objc_msgSend)(delegate, withIcon, items, MTPSettingsCategory, @"MaxTubePlus", nil, nil, NO);
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
    if (MTPClassWithSelectors(@"YTSettingsGroupData", @[@"orderedCategories", @"type"])) %init(SettingsGroups);
    [compat setStatus:@"Section registered" forModule:MTPModuleSettings];
}
