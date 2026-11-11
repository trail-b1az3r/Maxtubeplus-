// MaxTubePlus entry point. Each module installs its own hook group only after
// the compatibility layer has classified the running YouTube build. Modules
// never crash the app when a class/selector is missing: they log, record a
// status visible in Settings > MaxTubePlus, and stay inactive.
//
// Launch-crash guard: a counter file is written synchronously before any hook
// is installed and removed once the app has stayed in the foreground for a
// while. If YouTube dies during startup twice in a row, the next launch runs
// in safe mode (no feature modules; only the settings section, so the user can
// see what happened and leave safe mode). If even that crashes, MaxTubePlus
// installs nothing at all.

#import "Common/MTPCommon.h"

extern void MTPInstallContext(void);
extern void MTPInstallSettings(void);
extern void MTPInstallDownloads(void);
extern void MTPInstallDeArrow(void);
extern void MTPInstallRefreshRate(void);
extern void MTPInstallCreatorSuppression(void);
extern void MTPInstallAdvancedSearch(void);
extern void MTPInstallModernUI(void);

static const NSInteger kSafeModeAfterCrashes = 2;
static const NSInteger kDisableEverythingAfterCrashes = 4;
static const NSTimeInterval kStableAfterSeconds = 20;

static NSString *GuardPath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [support stringByAppendingPathComponent:@"MaxTubePlus"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory stringByAppendingPathComponent:@"LaunchGuard.plist"];
}

NSInteger MTPUnfinishedLaunchCount(void) {
    NSDictionary *guard = [NSDictionary dictionaryWithContentsOfFile:GuardPath()];
    return [guard[@"unfinished"] integerValue];
}

BOOL MTPSafeModeActive(void) {
    return [MTPPrefs boolForKey:@"general.safeMode"];
}

void MTPLeaveSafeMode(void) {
    [[NSFileManager defaultManager] removeItemAtPath:GuardPath() error:nil];
    [MTPPrefs setBool:NO forKey:@"general.safeMode"];
    [[MTPPrefs defaults] synchronize];
}

static void MarkLaunchStable(void) {
    [[NSFileManager defaultManager] removeItemAtPath:GuardPath() error:nil];
}

%ctor {
    @autoreleasepool {
        MTPCompat *compat = [MTPCompat shared];
        if (![compat.bundleIdentifier hasPrefix:@"com.google.ios.youtube"] && ![[NSBundle mainBundle].executablePath.lastPathComponent isEqualToString:@"YouTube"]) {
            MTPLog(@"not YouTube (%@); staying inactive", compat.bundleIdentifier);
            return;
        }

        NSInteger unfinished = MTPUnfinishedLaunchCount();
        // Synchronous, atomic write before any hook exists.
        [@{@"unfinished": @(unfinished + 1), @"version": @MTP_VERSION} writeToFile:GuardPath() atomically:YES];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStableAfterSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) MarkLaunchStable();
            });
        }];

        if (unfinished >= kDisableEverythingAfterCrashes) {
            MTPLog(@"%ld unfinished launches: MaxTubePlus fully disabled for this launch", (long)unfinished);
            // Reset so the next launch tries safe mode again instead of staying off forever.
            [@{@"unfinished": @(kSafeModeAfterCrashes)} writeToFile:GuardPath() atomically:YES];
            return;
        }
        if (unfinished >= kSafeModeAfterCrashes && !MTPSafeModeActive()) {
            [MTPPrefs setBool:YES forKey:@"general.safeMode"];
            [[MTPPrefs defaults] synchronize];
        }

        MTPLog(@"MaxTubePlus %s starting on YouTube %@ (unfinished launches: %ld%@)", MTP_VERSION, compat.appVersion,
               (long)unfinished, MTPSafeModeActive() ? @", SAFE MODE" : @"");

        if (MTPSafeModeActive()) {
            @try { MTPInstallSettings(); } @catch (NSException *e) { MTPLog(@"settings failed: %@", e); }
            for (NSInteger module = 0; module < MTPModuleCount; module++) {
                if (module != MTPModuleSettings) [compat setStatus:@"Off: safe mode (YouTube crashed during startup)" forModule:module];
            }
            return;
        }

        void (*installers[])(void) = {
            MTPInstallContext, MTPInstallSettings, MTPInstallModernUI, MTPInstallDownloads, MTPInstallDeArrow,
            MTPInstallRefreshRate, MTPInstallCreatorSuppression, MTPInstallAdvancedSearch,
        };
        for (size_t i = 0; i < sizeof(installers) / sizeof(installers[0]); i++) {
            @try {
                installers[i]();
            } @catch (NSException *exception) {
                MTPLog(@"installer %zu failed: %@", i, exception);
            }
        }
    }
}
