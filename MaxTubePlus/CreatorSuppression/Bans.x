// Banned creators (by @handle): hide all their videos, Shorts and posts.
//
//  * Feeds, search results, Shorts shelves and community posts are YouTube
//    elements: their bytes are matched against the banned channel ID, the
//    "@handle" token and the display name (MTPContext element filter). Hidden
//    elements collapse, so the next item takes their place.
//  * The Shorts player gets its videos from YTReelDataSource
//    (-contentModelsForEntries:, verified in YouTube 21.45.4). Each Short's
//    author comes from oEmbed (cached); banned Shorts are dropped from the
//    sequence and -[YTReelContentModel shouldDisplay] returns NO for them.
//  * The creator's own channel page is left alone so a ban can be undone from
//    there and nothing breaks if you open their channel on purpose.

#import <objc/runtime.h>
#import <objc/message.h>
#import "MTPBanStore.h"
#import "../Common/MTPContext.h"
#import "../Common/MTPVideoInfo.h"

static id Get(id target, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *ReelVideoID(id contentModel) {
    id command = Get(contentModel, @"command");
    id endpoint = nil;
    @try { endpoint = [command valueForKey:@"reelWatchEndpoint"]; } @catch (__unused NSException *e) {}
    NSString *videoID = nil;
    @try { videoID = [endpoint valueForKey:@"videoId"]; } @catch (__unused NSException *e) {}
    return [videoID isKindOfClass:[NSString class]] && mtp_is_video_id(videoID.UTF8String) ? videoID : nil;
}

static NSUInteger gBanGeneration = 1;
static const void *kReelVerdictKey = &kReelVerdictKey;

static NSNumber *ComputeReelIsBanned(id contentModel);

/// YES / NO when known; nil while the author is still being looked up (the
/// lookup is started and later reels are filtered once it completes).
/// Known verdicts are cached on the model until the ban list changes.
static NSNumber *ReelIsBanned(id contentModel) {
    if ([MTPBanStore shared].creators.count == 0) return @NO;
    NSNumber *cached = objc_getAssociatedObject(contentModel, kReelVerdictKey);
    if (cached && ([cached unsignedIntegerValue] >> 1) == gBanGeneration) return @([cached unsignedIntegerValue] & 1);
    NSNumber *verdict = ComputeReelIsBanned(contentModel);
    if (verdict) objc_setAssociatedObject(contentModel, kReelVerdictKey, @((gBanGeneration << 1) | (verdict.boolValue ? 1 : 0)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return verdict;
}

static NSNumber *ComputeReelIsBanned(id contentModel) {
    MTPBanStore *store = [MTPBanStore shared];
    id command = Get(contentModel, @"command");
    NSData *bytes = [[command description] dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes && [store bytesReferenceBannedCreator:bytes]) return @YES;
    NSString *videoID = ReelVideoID(contentModel);
    if (!videoID) return @NO;
    MTPVideoInfo *info = [[MTPVideoInfoProvider shared] cachedInfoForVideoID:videoID];
    if (!info) {
        [[MTPVideoInfoProvider shared] infoForVideoID:videoID completion:^(MTPVideoInfo *fetched) {}];
        return nil;
    }
    return @([store authorIsBannedWithName:info.authorName url:info.authorURL]);
}

%group BansShorts
%hook YTReelDataSource
- (NSArray *)contentModelsForEntries:(id)entries {
    NSArray *models = %orig;
    if (![models isKindOfClass:[NSArray class]] || [MTPBanStore shared].creators.count == 0) return models;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:models.count];
    for (id model in models) {
        if ([ReelIsBanned(model) boolValue]) { [[MTPBanStore shared] noteHidden]; continue; }
        [kept addObject:model];
    }
    // Never return an empty page: YouTube treats that as the end of Shorts.
    return kept.count ? kept : models;
}
%end

%hook YTReelContentModel
- (BOOL)shouldDisplay {
    if ([ReelIsBanned(self) boolValue]) return NO;
    return %orig;
}
%end
%end

NSString *MTPBansStatus(void) {
    MTPBanStore *store = [MTPBanStore shared];
    NSUInteger unresolved = 0;
    for (MTPBannedCreator *c in store.creators) if (!c.channelID) unresolved++;
    return [NSString stringWithFormat:@"%lu banned creator(s)%@, %lu item(s) hidden this session",
            (unsigned long)store.creators.count, unresolved ? [NSString stringWithFormat:@" (%lu still matched by handle only)", (unsigned long)unresolved] : @"",
            (unsigned long)store.hiddenCount];
}

void MTPInstallBans(void) {
    MTPCompat *compat = [MTPCompat shared];
    if (![compat mayInstallModule:MTPModuleSuppression]) return;
    MTPBanStore *store = [MTPBanStore shared];

    [MTPContext addElementFilter:^BOOL(NSData *bytes, MTPSurface surface) {
        if (surface == MTPSurfaceChannelPage || store.creators.count == 0) return NO;
        if (![store bytesReferenceBannedCreator:bytes]) return NO;
        [store noteHidden];
        return YES;
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:MTPBansChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        gBanGeneration++;
        MTPContextBumpFilterGeneration();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [store retryResolving];
    }];

    BOOL shorts = MTPClassWithSelectors(@"YTReelDataSource", @[@"contentModelsForEntries:"]) && MTPClassWithSelectors(@"YTReelContentModel", @[@"shouldDisplay", @"command"]);
    if (shorts) { %init(BansShorts); }
    MTPLog(@"bans: element filter active; Shorts player filtering %@", shorts ? @"active" : @"unavailable (YTReelDataSource API not found)");
}
