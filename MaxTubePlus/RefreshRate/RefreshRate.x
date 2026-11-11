// 120Hz Playback Enhancement (ProMotion).
//
// What actually limits YouTube to 60Hz on iPhone ProMotion displays:
//  1. Info.plist: without CADisableMinimumFrameDurationOnPhone=YES, iOS caps
//     every CADisplayLink / Core Animation commit of an iPhone app at 60Hz.
//     This cannot be changed at runtime; the MaxTubePlus workflow sets the key
//     while packaging (scripts/patch_info_plist.sh). The module reports
//     whether it is present.
//  2. Display links created with preferredFramesPerSecond = 60 (or a
//     frame-rate range capped at 60) for UI work such as scrolling,
//     scrubbing and player chrome animations. These caps are lifted to the
//     screen maximum.
//
// What is deliberately NOT touched:
//  * Display links that drive video frame presentation (targets from the
//    player/render pipeline). Their cadence is chosen by YouTube's renderer
//    to match the content frame rate; forcing 120Hz there would not create
//    real frames and could hurt pacing. 24/30/60fps content stays as is —
//    ProMotion simply refreshes at an integer multiple.
//  * Low Power Mode, where iOS itself limits to 60Hz.

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "../Common/MTPCommon.h"

static const void *kVideoLinkKey = &kVideoLinkKey;
static NSInteger gMaxFPS = 60;
static NSUInteger gLiftedLinks = 0;
static NSUInteger gSkippedVideoLinks = 0;

static BOOL MTPHighRefreshActive(void) {
    return gMaxFPS > 60 && [MTPPrefs boolForKey:MTPKeyHighRefreshEnabled] && ![NSProcessInfo processInfo].lowPowerModeEnabled;
}

static BOOL TargetLooksLikeVideoPipeline(id target) {
    if (!target) return NO;
    NSString *name = NSStringFromClass([target class]);
    for (NSString *marker in @[@"HAM", @"MLAV", @"Player", @"Video", @"Render", @"Metal", @"Media", @"Frame"]) {
        if ([name rangeOfString:marker].location != NSNotFound) return YES;
    }
    return NO;
}

static void LiftLink(CADisplayLink *link) {
    if (!MTPHighRefreshActive() || [objc_getAssociatedObject(link, kVideoLinkKey) boolValue]) return;
    if (@available(iOS 15.0, *)) {
        CAFrameRateRange range = link.preferredFrameRateRange;
        BOOL capped60 = range.maximum > 0 && range.maximum <= 60.0f && range.maximum >= 59.0f;
        BOOL unset = range.maximum == 0 && link.preferredFramesPerSecond == 0;
        BOOL fps60 = link.preferredFramesPerSecond == 60;
        if (capped60 || fps60 || unset) {
            link.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, (float)gMaxFPS, (float)gMaxFPS);
            gLiftedLinks++;
        }
    }
}

%group RefreshRate

%hook CADisplayLink
+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link = %orig;
    if (TargetLooksLikeVideoPipeline(target)) {
        objc_setAssociatedObject(link, kVideoLinkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gSkippedVideoLinks++;
    } else {
        LiftLink(link);
    }
    return link;
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    %orig;
    if (fps == 60) LiftLink(self);
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (MTPHighRefreshActive() && ![objc_getAssociatedObject(self, kVideoLinkKey) boolValue]
        && range.maximum >= 59.0f && range.maximum <= 60.0f) {
        // Keep the caller's minimum (frame pacing floor) but allow ProMotion.
        range = CAFrameRateRangeMake(range.minimum, (float)gMaxFPS, (float)gMaxFPS);
        gLiftedLinks++;
    }
    %orig(range);
}
%end

%end

NSString *MTPRefreshRateStatus(void) {
    BOOL plistKey = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"] boolValue];
    BOOL pad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    NSString *plistNote = pad ? @"iPad (no Info.plist key required)"
                              : (plistKey ? @"CADisableMinimumFrameDurationOnPhone present" : @"CADisableMinimumFrameDurationOnPhone MISSING — iOS caps app at 60Hz");
    return [NSString stringWithFormat:@"Screen max %ldHz; %@; %lu UI links lifted, %lu video links left untouched%@",
            (long)gMaxFPS, plistNote, (unsigned long)gLiftedLinks, (unsigned long)gSkippedVideoLinks,
            [NSProcessInfo processInfo].lowPowerModeEnabled ? @"; Low Power Mode active" : @""];
}

void MTPInstallRefreshRate(void) {
    MTPCompat *compat = [MTPCompat shared];
    gMaxFPS = [UIScreen mainScreen].maximumFramesPerSecond;
    if (!compat.proMotionDisplay) {
        [compat setStatus:@"Inactive: display is 60Hz (no ProMotion)" forModule:MTPModuleRefreshRate];
        return;
    }
    if (![compat mayInstallModule:MTPModuleRefreshRate]) {
        [compat setStatus:@"Disabled: unverified YouTube version" forModule:MTPModuleRefreshRate];
        return;
    }
    if (@available(iOS 15.0, *)) {
        %init(RefreshRate);
        [compat setStatus:@"Active" forModule:MTPModuleRefreshRate];
    } else {
        [compat setStatus:@"Inactive: requires iOS 15" forModule:MTPModuleRefreshRate];
    }
}
