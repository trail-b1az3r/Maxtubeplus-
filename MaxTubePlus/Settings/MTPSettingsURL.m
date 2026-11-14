// youtube://maxtubeplus (also youtube://maxtubeplus/settings) opens the
// MaxTubePlus settings from Safari, Shortcuts or a home-screen bookmark.
// A fallback that does not depend on YouTube's settings internals.

#import <objc/runtime.h>
#import "MTPSettingsViewController.h"
#import "../Common/MTPCommon.h"

static BOOL IsMaxTubePlusURL(NSURL *url) {
    return [url.host.lowercaseString isEqualToString:@"maxtubeplus"];
}

static void OpenSettingsSoon(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [MTPSettingsRootViewController presentFromTop];
    });
}

static void HookAppDelegate(Class cls) {
    SEL sel = @selector(application:openURL:options:);
    if (!class_getInstanceMethod(cls, sel)) {
        class_addMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self, UIApplication *app, NSURL *url, NSDictionary *options) {
            if (IsMaxTubePlusURL(url)) { OpenSettingsSoon(); return YES; }
            return NO;
        }), "B@:@@@");
        return;
    }
    __block BOOL (*original)(id, SEL, id, id, id) = NULL;
    MTPHookMethod(cls, sel, imp_implementationWithBlock(^BOOL(id self, UIApplication *app, NSURL *url, NSDictionary *options) {
        if (IsMaxTubePlusURL(url)) { OpenSettingsSoon(); return YES; }
        return original ? original(self, sel, app, url, options) : NO;
    }), (IMP *)&original);
}

static void HookSceneDelegate(Class cls) {
    static NSMutableSet *hooked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hooked = [NSMutableSet set]; });
    if (!cls || [hooked containsObject:cls]) return;
    [hooked addObject:cls];
    SEL sel = @selector(scene:openURLContexts:);
    __block void (*original)(id, SEL, id, id) = NULL;
    IMP replacement = imp_implementationWithBlock(^(id self, UIScene *scene, NSSet<UIOpenURLContext *> *contexts) {
        NSMutableSet *rest = [NSMutableSet set];
        for (UIOpenURLContext *context in contexts) {
            if (IsMaxTubePlusURL(context.URL)) OpenSettingsSoon();
            else [rest addObject:context];
        }
        if (rest.count && original) original(self, sel, scene, rest);
    });
    if (class_getInstanceMethod(cls, sel)) MTPHookMethod(cls, sel, replacement, (IMP *)&original);
    else class_addMethod(cls, sel, replacement, "v@:@@");
}

void MTPRegisterSettingsURL(void) {
    Class appDelegate = NSClassFromString(@"YTAppDelegate");
    if (appDelegate) HookAppDelegate(appDelegate);
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneWillConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        id delegate = [(UIScene *)note.object delegate];
        if (delegate) HookSceneDelegate([delegate class]);
    }];
}
