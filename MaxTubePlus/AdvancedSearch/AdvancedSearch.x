// Advanced Search.
//
//  Server side: YouTube's search "params" protobuf (the same bytes its own
//  filter chips send) is generated from the active filters: upload-date
//  bucket, duration bucket, type=video and sort-by-upload-date for recency.
//  It is only injected when YouTube itself did not set params, so YouTube's
//  own chips keep working.
//  Client side: exact bounds (duration in minutes, upload window, recency,
//  minimum likes) are applied to every rendered search result element.
//  Entry points: long-press the search button, or Settings > MaxTubePlus.

#import <objc/runtime.h>
#import "MTPSearchFilterState.h"
#import "MTPSearchFilterViewController.h"
#import "../Common/MTPContext.h"
#import "../Common/MTPYouTube.h"

extern void MTPContextBumpFilterGeneration(void);

static NSMutableSet<NSString *> *gPendingLikes;
static BOOL gLikesFetchScheduled = NO;
static NSUInteger gHiddenResults = 0;
static const void *kLongPressKey = &kLongPressKey;

static BOOL FiltersOn(void) {
    return [MTPPrefs boolForKey:MTPKeySearchFiltersEnabled];
}

static void ReloadVisibleSearchResults(void) {
    UIViewController *list = [MTPContext currentSectionList];
    if ([MTPContext currentSurface] != MTPSurfaceSearch || !list) return;
    MTPContextBumpFilterGeneration();
    for (NSString *key in @[@"collectionView", @"_collectionView"]) {
        @try {
            id view = [list valueForKey:key];
            if ([view respondsToSelector:@selector(reloadData)]) { [view reloadData]; return; }
        } @catch (__unused NSException *e) {}
    }
}

static void ScheduleLikesFetch(void) {
    if (gLikesFetchScheduled) return;
    gLikesFetchScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray *ids;
        @synchronized (gPendingLikes) { ids = gPendingLikes.allObjects; [gPendingLikes removeAllObjects]; }
        gLikesFetchScheduled = NO;
        if (ids.count == 0) return;
        [[MTPLikesProvider shared] fetchLikesForVideoIDs:ids completion:^{ ReloadVisibleSearchResults(); }];
    });
}

%group SearchParams
%hook YTISearchEndpoint
- (NSString *)params {
    NSString *original = %orig;
    if (original.length || !FiltersOn()) return original;
    NSString *ours = [[MTPSearchFilterState shared] encodedSearchParams];
    return ours ?: original;
}
%end
%end

%group SearchEntry
%hook YTRightNavigationButtons
- (void)layoutSubviews {
    %orig;
    UIView *search = nil;
    @try { search = [self valueForKey:@"searchButton"]; } @catch (__unused NSException *e) {}
    if (![search isKindOfClass:[UIView class]] || objc_getAssociatedObject(search, kLongPressKey)) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:[MTPSearchFilterViewController class] action:@selector(mtp_longPress:)];
    press.minimumPressDuration = 0.4;
    [search addGestureRecognizer:press];
    objc_setAssociatedObject(search, kLongPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%end

@interface MTPSearchFilterViewController (Entry)
+ (void)mtp_longPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation MTPSearchFilterViewController (Entry)
+ (void)mtp_longPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self presentFromTop];
}
@end

NSString *MTPAdvancedSearchStatus(void) {
    MTPSearchFilterState *state = [MTPSearchFilterState shared];
    return [NSString stringWithFormat:@"%lu active filter(s), sort: %@, %lu result(s) hidden this session",
            (unsigned long)state.activeKinds.count, state.sortMode == MTPSortRecency ? @"recency" : @"relevance", (unsigned long)gHiddenResults];
}

void MTPInstallAdvancedSearch(void) {
    MTPCompat *compat = [MTPCompat shared];
    if (![compat mayInstallModule:MTPModuleSearch]) {
        [compat setStatus:@"Disabled: unverified YouTube version" forModule:MTPModuleSearch];
        return;
    }
    gPendingLikes = [NSMutableSet set];
    NSMutableArray *notes = [NSMutableArray array];

    [MTPContext addElementFilter:^BOOL(NSData *bytes, MTPSurface surface) {
        if (surface != MTPSurfaceSearch || !FiltersOn()) return NO;
        MTPSearchFilterState *state = [MTPSearchFilterState shared];
        if (![state hasActiveFilters]) return NO;
        NSString *videoID = nil;
        MTPVideoFacts facts = [MTPSearchFilterState factsFromElementBytes:bytes videoID:&videoID];
        if (!videoID) return NO; // not a video result (channel, playlist, chips...)
        MTPSearchFilter filter = [state cFilter];
        MTPFilterResult result = mtp_filter_evaluate(&filter, &facts, (long long)[NSDate date].timeIntervalSince1970);
        if (result == MTPFilterUnknown && filter.minLikes >= 0 && facts.likes < 0 && [MTPPrefs boolForKey:MTPKeySearchFetchLikes]) {
            @synchronized (gPendingLikes) { [gPendingLikes addObject:videoID]; }
            dispatch_async(dispatch_get_main_queue(), ^{ ScheduleLikesFetch(); });
        }
        BOOL hide = result != MTPFilterPass && result != MTPFilterUnknown;
        if (hide) gHiddenResults++;
        return hide;
    }];
    [notes addObject:@"result filtering via element hook"];

    if (MTPClassWithSelectors(@"YTISearchEndpoint", @[@"params"])) {
        %init(SearchParams);
        [notes addObject:@"server params hooked"];
    } else {
        [notes addObject:@"YTISearchEndpoint.params missing (client-side only)"];
    }
    if (NSClassFromString(@"YTRightNavigationButtons")) {
        %init(SearchEntry);
        [notes addObject:@"long-press search entry"];
    }
    [compat setStatus:[notes componentsJoinedByString:@"; "] forModule:MTPModuleSearch];
}
