// Background Downloads.
//
// Relationship with YTPlus's downloader: YTPlus (closed source) has its own
// in-process engine (YTPlus 6.0 strings: handOverToDownloader, pauseDownload,
// maxConcurrentDownloads...). Its internals cannot be patched safely, so
// MaxTubePlus leaves it untouched and adds a *background-capable* path next to
// it: a background NSURLSession that keeps transferring while YouTube is
// suspended or killed, a persistent queue, pause/resume/cancel/retry,
// recovery on relaunch, notifications and storage management. Both coexist;
// YTPlus's Download button keeps working exactly as before.

#import <objc/runtime.h>
#import "MTPDownloadManager.h"
#import "MTPDownloadsViewController.h"
#import "../Common/MTPContext.h"

static BOOL HandleBackgroundEvents(NSString *identifier, void (^completion)(void)) {
    if (![identifier isEqualToString:[MTPDownloadManager sessionIdentifier]]) return NO;
    // Creating the shared manager reconnects to the background session.
    [MTPDownloadManager shared].backgroundCompletionHandler = completion;
    return YES;
}

static void InstallBackgroundSessionHandler(void) {
    Class delegateClass = NSClassFromString(@"YTAppDelegate");
    if (!delegateClass) delegateClass = [[UIApplication sharedApplication].delegate class];
    if (!delegateClass) return;
    SEL selector = @selector(application:handleEventsForBackgroundURLSession:completionHandler:);
    Method existing = class_getInstanceMethod(delegateClass, selector);
    if (existing) {
        __block void (*original)(id, SEL, id, id, id) = (void *)method_getImplementation(existing);
        method_setImplementation(existing, imp_implementationWithBlock(^(id self, UIApplication *app, NSString *identifier, void (^completion)(void)) {
            if (!HandleBackgroundEvents(identifier, completion)) original(self, selector, app, identifier, completion);
        }));
    } else {
        class_addMethod(delegateClass, selector, imp_implementationWithBlock(^(id self, UIApplication *app, NSString *identifier, void (^completion)(void)) {
            if (!HandleBackgroundEvents(identifier, completion)) completion();
        }), "v@:@@@?");
    }
}

void MTPInstallDownloads(void) {
    MTPCompat *compat = [MTPCompat shared];
    if (![compat mayInstallModule:MTPModuleDownloads]) {
        [compat setStatus:@"Disabled: unverified YouTube version" forModule:MTPModuleDownloads];
        return;
    }
    InstallBackgroundSessionHandler();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if ([MTPPrefs boolForKey:MTPKeyDownloadsEnabled]) [[MTPDownloadManager shared] reconcileAfterLaunch];
    }];

    [MTPContext addSheetDecorator:^(id sheet, MTPItemContext *context) {
        if (![MTPPrefs boolForKey:MTPKeyDownloadsEnabled] || ![sheet respondsToSelector:@selector(addAction:)]) return;
        id player = [MTPContext currentPlayer];
        NSString *playing = [MTPContext currentVideoID];
        // Streams are only available for the video loaded in the player.
        if (!player || !playing || (context.videoID && ![context.videoID isEqualToString:playing])) return;
        id action = [MTPContext makeSheetActionWithTitle:@"Download in background (MaxTubePlus)" iconType:0 handler:^{
            NSString *error = [[MTPDownloadManager shared] enqueueFromPlayer:player];
            MTPToast(error ? [@"MaxTubePlus: " stringByAppendingString:error] : @"MaxTubePlus: download queued");
        }];
        if (action) [sheet performSelector:@selector(addAction:) withObject:action];
    }];

    [compat setStatus:@"Active: background session + sheet action" forModule:MTPModuleDownloads];
}
