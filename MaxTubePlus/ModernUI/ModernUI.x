// Modern UI Compatibility: floating menu + YTPlus dock customisation +
// Subscriptions tab, without spoofing the iOS version.
//
// Hook points
//  1. -[YTPivotBarView setRenderer:]   classic bar (also used when spoofed).
//  2. Runtime-discovered pivot/tab-bar consumers in YouTube's own images whose
//     single-object setter receives a YTIPivotBarRenderer/YTIGuideResponse.
//     This covers the floating bar in 21.4x without hard-coding a class name
//     that is not present in public headers, and logs exactly what was hooked.
// Every hook mutates the *renderer* and then calls YTPlus's own
// +[YTPTabHelper applyCustomTabsToPivotBarRenderer:], so YTPlus's tab editor
// remains the source of truth for order/visibility.

#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "MTPTabLayout.h"
#import "../Common/MTPYouTube.h"

static NSMutableSet<NSString *> *gHookedConsumers;

static BOOL ArgumentLooksLikePivotData(id argument, BOOL *isGuide) {
    static Class pivotClass, guideClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pivotClass = NSClassFromString(@"YTIPivotBarRenderer");
        guideClass = NSClassFromString(@"YTIGuideResponse");
    });
    if (pivotClass && [argument isKindOfClass:pivotClass]) { *isGuide = NO; return YES; }
    if (guideClass && [argument isKindOfClass:guideClass]) { *isGuide = YES; return YES; }
    return NO;
}

static void HookConsumer(Class cls, SEL selector) {
    NSString *key = [NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(selector)];
    @synchronized (gHookedConsumers) {
        if ([gHookedConsumers containsObject:key]) return;
        [gHookedConsumers addObject:key];
    }
    __block void (*original)(id, SEL, id) = NULL;
    NSString *source = NSStringFromClass(cls);
    IMP replacement = imp_implementationWithBlock(^(id self, id argument) {
        BOOL isGuide = NO;
        if (ArgumentLooksLikePivotData(argument, &isGuide)) {
            if (isGuide) [[MTPTabLayout shared] applyToGuideResponse:argument source:source];
            else [[MTPTabLayout shared] applyToPivotBarRenderer:argument source:source applyYTPlus:YES];
        }
        if (original) original(self, selector, argument);
    });
    if (MTPHookMethod(cls, selector, replacement, (IMP *)&original)) MTPLog(@"modernui: hooked consumer %@", key);
}

static BOOL ImageBelongsToApp(const char *imageName) {
    if (!imageName) return NO;
    NSString *path = @(imageName);
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    if (![path hasPrefix:bundlePath]) return NO;
    // Skip injected dylibs (YTPlus, MaxTubePlus, other tweaks).
    return ![path hasSuffix:@".dylib"];
}

/// Finds pivot/tab-bar classes in YouTube's own images whose single-object
/// setters may receive pivot data, and hooks them.
static void DiscoverPivotConsumers(void) {
    static NSArray<NSString *> *selectorNames;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        selectorNames = @[@"setRenderer:", @"setPivotBarRenderer:", @"updateWithRenderer:", @"updateWithPivotBarRenderer:",
                          @"configureWithRenderer:", @"setGuideResponse:", @"updateWithGuideResponse:", @"setPivotRenderer:"];
    });
    NSSet *excluded = [NSSet setWithArray:@[@"YTPivotBarView", @"YTPivotBarItemView", @"YTPivotBarIndicatorView",
                                            @"YTIPivotBarRenderer", @"YTIPivotBarSupportedRenderers", @"YTIPivotBarItemRenderer"]];
    // objc_copyClassNamesForImage returns names WITHOUT realizing classes.
    // (objc_copyClassList would realize every class in the process at launch,
    // which is slow and can crash on Swift classes with unavailable superclasses.)
    unsigned int classCount = 0;
    NSUInteger candidates = 0;
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t image = 0; image < imageCount; image++) {
        const char *imagePath = _dyld_get_image_name(image);
        if (!imagePath || ![@(imagePath) hasPrefix:bundlePath] || !ImageBelongsToApp(imagePath)) continue;
        unsigned int nameCount = 0;
        const char **names = objc_copyClassNamesForImage(imagePath, &nameCount);
        classCount += nameCount;
        for (unsigned int i = 0; i < nameCount; i++) {
            const char *rawName = names[i];
            // Objective-C (YT*) and Swift (mangled _Tt*) classes are both considered.
            if (strncmp(rawName, "YT", 2) != 0 && strncmp(rawName, "_Tt", 3) != 0) continue;
            if (!strstr(rawName, "PivotBar") && !strstr(rawName, "TabBar") && !strstr(rawName, "Guide")) continue;
            if (strncmp(rawName, "YTI", 3) == 0) continue; // protobuf messages, not consumers
            if ([excluded containsObject:@(rawName)]) continue;
            Class cls = objc_getClass(rawName);
            if (!cls) continue;
            candidates++;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned int m = 0; m < methodCount; m++) {
                NSString *selName = NSStringFromSelector(method_getName(methods[m]));
                if (![selectorNames containsObject:selName]) continue;
                char returnType[8] = {0};
                method_getReturnType(methods[m], returnType, sizeof(returnType));
                if (method_getNumberOfArguments(methods[m]) != 3 || returnType[0] != 'v') continue;
                char argType[8] = {0};
                method_getArgumentType(methods[m], 2, argType, sizeof(argType));
                if (argType[0] != '@') continue;
                HookConsumer(cls, method_getName(methods[m]));
            }
            free(methods);
        }
        free(names);
    }
    MTPLog(@"modernui: scanned %u classes, %lu pivot/tab candidates, %lu consumers hooked",
           classCount, (unsigned long)candidates, (unsigned long)gHookedConsumers.count);
}

%group ModernUIClassic
%hook YTPivotBarView
- (void)setRenderer:(id)renderer {
    // YTPlus hooks this same method and runs its own tab helper here, so it is
    // NOT invoked a second time (re-entrant double application on the first
    // layout is a crash risk). Only floating-menu consumers, which YTPlus
    // does not reach, get YTPTabHelper applied by MaxTubePlus.
    [[MTPTabLayout shared] applyToPivotBarRenderer:renderer source:@"YTPivotBarView" applyYTPlus:NO];
    %orig;
}
%end
%end

void MTPInstallModernUI(void) {
    MTPCompat *compat = [MTPCompat shared];
    if (![compat mayInstallModule:MTPModuleModernUI]) {
        [compat setStatus:@"Disabled: unverified YouTube version" forModule:MTPModuleModernUI];
        return;
    }
    gHookedConsumers = [NSMutableSet set];
    NSMutableArray *notes = [NSMutableArray array];
    if (MTPClassWithSelectors(@"YTPivotBarView", @[@"setRenderer:"])) {
        %init(ModernUIClassic);
        [notes addObject:@"classic bar hooked"];
    } else {
        [notes addObject:@"YTPivotBarView missing"];
    }
    if (!NSClassFromString(@"YTIPivotBarRenderer")) [notes addObject:@"YTIPivotBarRenderer missing (Subscriptions restore unavailable)"];
    DiscoverPivotConsumers();
    // Frameworks loaded later (YouTube lazily loads some modules) are scanned
    // again once the app has finished launching.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        DiscoverPivotConsumers();
        [compat setStatus:[NSString stringWithFormat:@"%@; %lu floating/other consumers hooked", [notes componentsJoinedByString:@"; "], (unsigned long)gHookedConsumers.count] forModule:MTPModuleModernUI];
    }];
    [compat setStatus:[NSString stringWithFormat:@"%@; %lu floating/other consumers hooked", [notes componentsJoinedByString:@"; "], (unsigned long)gHookedConsumers.count] forModule:MTPModuleModernUI];
}
