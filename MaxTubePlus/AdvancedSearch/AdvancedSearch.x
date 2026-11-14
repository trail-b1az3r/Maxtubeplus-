// Advanced Search — replaces YouTube's own search-filter UI.
//
//  Entry point: YouTube's filter button on the search results screen opens the
//  MaxTubePlus filter panel instead of YouTube's "Search filters" sheet.
//  Because the 21.42.4 filter button class is not in public headers, three
//  independent interception layers are used (each logs when it fires, with
//  Settings > MaxTubePlus > General > Debug logging):
//    1. UIControl taps (UIApplication -sendAction:to:from:forEvent:) from a
//       control labelled as a filter inside the search screen;
//    2. YouTube commands whose payload opens the search-filter dialog
//       (YTCommandResponderEvent factories + -send);
//    3. presentation of YouTube's own search-filter view controller.
//  Applying the panel re-runs the current query with YouTube's search params
//  protobuf (upload date bucket, duration bucket, type=video, sort), so the
//  server applies the filters; exact bounds (minutes, likes, date window) are
//  then enforced on the rendered results.

#import <objc/runtime.h>
#import <objc/message.h>
#import "MTPSearchFilterState.h"
#import "MTPSearchFilterViewController.h"
#import "../Common/MTPContext.h"
#import "../Common/MTPYouTube.h"

static NSMutableSet<NSString *> *gPendingLikes;
static BOOL gLikesFetchScheduled = NO;
static NSUInteger gHiddenResults = 0;
static NSString *gLastQuery;
static NSString *gLastInterception = @"none yet";
static const void *kFilterEventKey = &kFilterEventKey;

static BOOL FiltersOn(void) {
    return [MTPPrefs boolForKey:MTPKeySearchFiltersEnabled];
}

static void Debug(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Debug(NSString *format, ...) {
    if (![MTPPrefs boolForKey:MTPKeyDebugLogging]) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    MTPLog(@"search: %@", message);
}

#pragma mark - Running a search

NSString *MTPLastSearchQuery(void) { return gLastQuery; }

static id NewMessage(NSString *className) {
    Class cls = NSClassFromString(className);
    SEL message = NSSelectorFromString(@"message");
    if ([cls respondsToSelector:message]) return ((id (*)(id, SEL))objc_msgSend)(cls, message);
    return [cls new];
}

/// Re-runs `query` with the active MaxTubePlus filters. Prefers YouTube's own
/// navigation (a search command sent through the responder chain); falls back
/// to YouTube's results deep link handled by the app itself.
void MTPRunSearch(NSString *query) {
    if (query.length == 0) {
        MTPToast(@"MaxTubePlus: filters saved — they apply to your next search.");
        return;
    }
    MTPContextBumpFilterGeneration();
    NSString *params = [[MTPSearchFilterState shared] encodedSearchParams] ?: @"";

    id endpoint = NewMessage(@"YTISearchEndpoint");
    id command = NewMessage(@"YTICommand");
    SEL setSearch = NSSelectorFromString(@"setSearchEndpoint:");
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    SEL factory = NSSelectorFromString(@"eventWithCommand:fromView:entry:sendClick:firstResponder:");
    UIViewController *responder = [MTPContext currentSectionList] ?: MTPTopViewController();
    if (endpoint && command && [command respondsToSelector:setSearch] && [eventClass respondsToSelector:factory] && responder) {
        @try {
            [endpoint setValue:query forKey:@"query"];
            [endpoint setValue:params forKey:@"params"];
            ((void (*)(id, SEL, id))objc_msgSend)(command, setSearch, endpoint);
            id event = ((id (*)(id, SEL, id, id, id, BOOL, id))objc_msgSend)(eventClass, factory, command, responder.view, nil, NO, responder);
            if ([event respondsToSelector:@selector(send)]) {
                [event performSelector:@selector(send)];
                Debug(@"re-ran \"%@\" via command, params=%@", query, params);
                return;
            }
        } @catch (NSException *exception) {
            MTPLog(@"search: command path failed: %@", exception);
        }
    }
    // Fallback: YouTube's own results URL (handled in-app).
    NSURLComponents *components = [NSURLComponents componentsWithString:@"youtube://www.youtube.com/results"];
    NSMutableArray *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"search_query" value:query]];
    NSString *plainParams = [params stringByReplacingOccurrencesOfString:@"%3D" withString:@"="];
    if (plainParams.length) [items addObject:[NSURLQueryItem queryItemWithName:@"sp" value:plainParams]];
    components.queryItems = items;
    Debug(@"re-ran \"%@\" via URL %@", query, components.URL);
    [[UIApplication sharedApplication] openURL:components.URL options:@{} completionHandler:nil];
}

static void PresentPanel(NSString *via) {
    // One tap can reach several interception paths (e.g. -sendIfEventHandlerAvailable
    // calling -send); open the panel once.
    static CFAbsoluteTime lastPresented = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastPresented < 1.0) return;
    lastPresented = now;
    gLastInterception = via;
    Debug(@"YouTube filter UI intercepted via %@", via);
    dispatch_async(dispatch_get_main_queue(), ^{ [MTPSearchFilterViewController presentFromTop]; });
}

#pragma mark - Interception helpers

static BOOL TextLooksLikeFilter(NSString *text) {
    NSString *lower = text.lowercaseString;
    // "Search filters", "Filters", "Filtros", "Filtre", "Filtri", "Filtr…", "Фильтры", "フィルタ", "筛选", "필터"
    for (NSString *marker in @[@"filter", @"filtr", @"filtre", @"фильтр", @"フィルタ", @"筛选", @"篩選", @"필터", @"تصفية"]) {
        if ([lower containsString:marker]) return YES;
    }
    return NO;
}

static BOOL InSearchScreen(id responder) {
    if ([MTPContext currentSurface] == MTPSurfaceSearch) return YES;
    return [MTPResponderChainDescription(responder) rangeOfString:@"Search"].location != NSNotFound;
}

static BOOL IsYouTubeFilterControl(id sender) {
    if (![sender isKindOfClass:[UIView class]]) return NO;
    UIView *view = sender;
    // Our own panel and settings are never intercepted.
    if ([MTPResponderChainDescription(view) rangeOfString:@"MTP"].location != NSNotFound) return NO;
    NSString *label = view.accessibilityLabel ?: @"";
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    if (!TextLooksLikeFilter(label) && !TextLooksLikeFilter(identifier)) return NO;
    return InSearchScreen(view);
}

static BOOL CommandOpensSearchFilters(id command) {
    if (!command) return NO;
    NSString *description = [command description];
    for (NSString *marker in @[@"search_filter", @"searchFilter", @"SearchFilter", @"search_filters", @"filter_options_dialog", @"searchFilterOptionsDialog"]) {
        if ([description rangeOfString:marker].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL ControllerIsYouTubeFilterSheet(UIViewController *controller) {
    UIViewController *target = controller;
    if ([target isKindOfClass:[UINavigationController class]]) target = [(UINavigationController *)target viewControllers].firstObject ?: target;
    NSString *name = NSStringFromClass([target class]);
    if ([name hasPrefix:@"MTP"]) return NO;
    if ([name rangeOfString:@"SearchFilter"].location != NSNotFound) return YES;
    return [target.title isKindOfClass:[NSString class]] && TextLooksLikeFilter(target.title) && InSearchScreen(MTPTopViewController());
}

static BOOL ShouldReplace(void) {
    return FiltersOn() && [MTPPrefs boolForKey:MTPKeySearchReplaceYouTubeFilters];
}

#pragma mark - YouTube's filter button (verified in YouTube 21.45.4)

/// YouTube's filter button on the results page sends a
/// YTShowSearchFiltersResponderEvent (initWithSearchFilters:view:fromRect:
/// firstResponder:), and the results overflow menu sends a
/// YTSearchFiltersOverflowMenuResponderEvent. Both are YTResponderEvent
/// subclasses, delivered via -send / -sendIfEventHandlerAvailable /
/// -sendWithStrictHandling:. Overriding those on the subclasses only replaces
/// YouTube's filter sheet and nothing else.
static void InterceptResponderEvent(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    NSString *via = [@"YouTube filter button (" stringByAppendingFormat:@"%@)", className];
    SEL send = @selector(send);
    __block void (*origSend)(id, SEL) = NULL;
    MTPHookMethod(cls, send, imp_implementationWithBlock(^(id self) {
        if (ShouldReplace()) { PresentPanel(via); return; }
        if (origSend) origSend(self, send);
    }), (IMP *)&origSend);
    SEL ifAvailable = NSSelectorFromString(@"sendIfEventHandlerAvailable");
    __block void (*origIfAvailable)(id, SEL) = NULL;
    MTPHookMethod(cls, ifAvailable, imp_implementationWithBlock(^(id self) {
        if (ShouldReplace()) { PresentPanel(via); return; }
        if (origIfAvailable) origIfAvailable(self, ifAvailable);
    }), (IMP *)&origIfAvailable);
    SEL strict = NSSelectorFromString(@"sendWithStrictHandling:");
    __block BOOL (*origStrict)(id, SEL, BOOL) = NULL;
    MTPHookMethod(cls, strict, imp_implementationWithBlock(^BOOL(id self, BOOL strictHandling) {
        if (ShouldReplace()) { PresentPanel(via); return YES; }
        return origStrict ? origStrict(self, strict, strictHandling) : NO;
    }), (IMP *)&origStrict);
}

#pragma mark - Hooks

%group SearchParams
%hook YTISearchEndpoint
- (NSString *)params {
    NSString *original = %orig;
    NSString *query = nil;
    @try { query = [self valueForKey:@"query"]; } @catch (__unused NSException *e) {}
    if ([query isKindOfClass:[NSString class]] && query.length) {
        gLastQuery = [query copy];
        MTPContextSetSurface(MTPSurfaceSearch);
    }
    if (original.length || !FiltersOn()) return original;
    NSString *ours = [[MTPSearchFilterState shared] encodedSearchParams];
    return ours ?: original;
}
%end
%end

%group SearchControlTaps
%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    if (ShouldReplace() && IsYouTubeFilterControl(sender)) {
        PresentPanel([NSString stringWithFormat:@"control tap (%@ \"%@\")", NSStringFromClass([sender class]), [sender accessibilityLabel] ?: [sender accessibilityIdentifier]]);
        return YES;
    }
    return %orig;
}
%end
%end

%group SearchCommands
%hook YTCommandResponderEvent
+ (id)eventWithCommand:(id)command fromView:(UIView *)view entry:(id)entry sendClick:(BOOL)sendClick firstResponder:(id)firstResponder {
    id event = %orig;
    if (event && CommandOpensSearchFilters(command)) objc_setAssociatedObject(event, kFilterEventKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return event;
}
+ (id)eventWithCommand:(id)command entry:(id)entry sendClick:(BOOL)sendClick firstResponder:(id)firstResponder {
    id event = %orig;
    if (event && CommandOpensSearchFilters(command)) objc_setAssociatedObject(event, kFilterEventKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return event;
}
- (void)send {
    if ([objc_getAssociatedObject(self, kFilterEventKey) boolValue] && ShouldReplace()) {
        PresentPanel(@"search-filter command");
        return;
    }
    %orig;
}
%end
%end

%group SearchPresentation
%hook UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    if (ShouldReplace() && ControllerIsYouTubeFilterSheet(controller)) {
        PresentPanel([NSString stringWithFormat:@"presentation of %@", NSStringFromClass([controller class])]);
        if (completion) completion();
        return;
    }
    %orig;
}
%end
%end

#pragma mark - Result refinement

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

NSString *MTPAdvancedSearchStatus(void) {
    MTPSearchFilterState *state = [MTPSearchFilterState shared];
    return [NSString stringWithFormat:@"%lu active filter(s), sort: %@, %lu result(s) hidden this session\nLast query: %@\nYouTube filter UI last replaced via: %@",
            (unsigned long)state.activeKinds.count, state.sortMode == MTPSortRecency ? @"recency" : @"relevance", (unsigned long)gHiddenResults,
            gLastQuery ?: @"—", gLastInterception];
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
    [notes addObject:@"result refinement"];

    if (MTPClassWithSelectors(@"YTISearchEndpoint", @[@"params"])) { %init(SearchParams); [notes addObject:@"search params"]; }
    else [notes addObject:@"YTISearchEndpoint.params missing"];
    InterceptResponderEvent(@"YTShowSearchFiltersResponderEvent");
    InterceptResponderEvent(@"YTSearchFiltersOverflowMenuResponderEvent");
    %init(SearchControlTaps);
    %init(SearchPresentation);
    [notes addObject:NSClassFromString(@"YTShowSearchFiltersResponderEvent") ? @"YouTube filter button (YTShowSearchFiltersResponderEvent)" : @"YTShowSearchFiltersResponderEvent missing"];
    [notes addObject:@"fallbacks: control taps + filter sheet presentation"];
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    if (eventClass && [eventClass instancesRespondToSelector:@selector(send)]) { %init(SearchCommands); [notes addObject:@"filter command interception"]; }
    [compat setStatus:[notes componentsJoinedByString:@"; "] forModule:MTPModuleSearch];
}
