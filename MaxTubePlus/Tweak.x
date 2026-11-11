// MaxTubePlus entry point. Each module installs its own hook group only after
// the compatibility layer has classified the running YouTube build. Modules
// never crash the app when a class/selector is missing: they log, record a
// status visible in Settings > MaxTubePlus, and stay inactive.

#import "Common/MTPCommon.h"

extern void MTPInstallContext(void);
extern void MTPInstallSettings(void);
extern void MTPInstallDownloads(void);
extern void MTPInstallDeArrow(void);
extern void MTPInstallRefreshRate(void);
extern void MTPInstallCreatorSuppression(void);
extern void MTPInstallAdvancedSearch(void);
extern void MTPInstallModernUI(void);

%ctor {
    @autoreleasepool {
        MTPCompat *compat = [MTPCompat shared];
        if (![compat.bundleIdentifier hasPrefix:@"com.google.ios.youtube"] && ![[NSBundle mainBundle].executablePath.lastPathComponent isEqualToString:@"YouTube"]) {
            MTPLog(@"not YouTube (%@); staying inactive", compat.bundleIdentifier);
            return;
        }
        MTPLog(@"MaxTubePlus %s starting: %@", MTP_VERSION, compat.summary);
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
