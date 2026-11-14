// Shared runtime context used by several MaxTubePlus modules:
//  * which surface (Home, Shorts, Search, channel...) is on screen,
//  * the active player,
//  * a single hook on element bytes (YTIElementRenderer -elementData) that
//    fans out to module filters/observers (YTLite uses the same hook point for
//    ad/shorts removal, so it is a proven integration point),
//  * menu sheet decoration (adding/wrapping actions).
// All hooks are installed only when their class/selector exists.

#import <objc/runtime.h>
#import <objc/message.h>
#import "MTPContext.h"
#import "MTPYouTube.h"

@implementation MTPItemContext
- (instancetype)init {
    if ((self = [super init])) _texts = @[];
    return self;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<item video=%@ channel=%@ name=%@ player=%d>", _videoID, _channelID, _channelName, _fromPlayer];
}
@end

static NSString *gCurrentTab = @"FEwhat_to_watch";
static MTPSurface gSurface = MTPSurfaceHome;
static __weak id gPlayer;
static __weak UIViewController *gSectionList;
static NSMutableArray<MTPElementFilter> *gFilters;
static NSMutableArray<MTPElementObserver> *gObservers;
static NSMutableArray<MTPSheetDecorator> *gDecorators;
static NSUInteger gFilterGeneration = 1;
static const void *kVerdictKey = &kVerdictKey;

static id Send0(id target, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    return (target && [target respondsToSelector:sel]) ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

static MTPSurface SurfaceForTab(NSString *tab) {
    if ([tab isEqualToString:@"FEshorts"]) return MTPSurfaceShorts;
    if ([tab isEqualToString:@"FEsubscriptions"]) return MTPSurfaceSubscriptions;
    if ([tab isEqualToString:@"FEexplore"] || [tab isEqualToString:@"FEtrending"]) return MTPSurfaceExplore;
    if ([tab isEqualToString:@"FEwhat_to_watch"]) return MTPSurfaceHome;
    return MTPSurfaceOther;
}

static MTPSurface ClassifyController(UIViewController *controller) {
    NSString *chain = MTPResponderChainDescription(controller);
    if ([chain rangeOfString:@"Search"].location != NSNotFound) {
        // Channel search inside a channel page counts as channel search.
        if ([chain rangeOfString:@"Channel"].location != NSNotFound) return MTPSurfaceChannelSearch;
        return MTPSurfaceSearch;
    }
    if ([chain rangeOfString:@"Channel"].location != NSNotFound) return MTPSurfaceChannelPage;
    if ([chain rangeOfString:@"Reel"].location != NSNotFound || [chain rangeOfString:@"Shorts"].location != NSNotFound) return MTPSurfaceShorts;
    if ([chain rangeOfString:@"Watch"].location != NSNotFound) return MTPSurfaceWatchNext;
    return SurfaceForTab(gCurrentTab);
}

@implementation MTPContext

+ (MTPSurface)currentSurface { return gSurface; }

+ (NSString *)nameForSurface:(MTPSurface)surface {
    switch (surface) {
        case MTPSurfaceHome: return @"Home";
        case MTPSurfaceShorts: return @"Shorts";
        case MTPSurfaceWatchNext: return @"Watch next";
        case MTPSurfaceExplore: return @"Explore";
        case MTPSurfaceSubscriptions: return @"Subscriptions";
        case MTPSurfaceSearch: return @"Search";
        case MTPSurfaceChannelSearch: return @"Channel search";
        case MTPSurfaceChannelPage: return @"Channel page";
        default: return @"Other";
    }
}

+ (id)currentPlayer { return gPlayer; }
+ (NSString *)currentVideoID {
    NSString *video = Send0(gPlayer, @"contentVideoID") ?: Send0(gPlayer, @"currentVideoID");
    return [video isKindOfClass:[NSString class]] && video.length ? video : nil;
}
+ (NSString *)currentChannelID {
    NSString *channel = Send0(gPlayer, @"channelID");
    return [channel isKindOfClass:[NSString class]] && channel.length ? channel : nil;
}
+ (UIViewController *)currentSectionList { return gSectionList; }

+ (void)addElementFilter:(MTPElementFilter)filter {
    @synchronized (gFilters) { [gFilters addObject:[filter copy]]; }
}
+ (void)addElementObserver:(MTPElementObserver)observer {
    @synchronized (gObservers) { [gObservers addObject:[observer copy]]; }
}
+ (void)addSheetDecorator:(MTPSheetDecorator)decorator {
    @synchronized (gDecorators) { [gDecorators addObject:[decorator copy]]; }
}

+ (NSString *)titleOfSheetAction:(id)action {
    for (NSString *key in @[@"title", @"_title"]) {
        @try {
            id value = [action valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
        } @catch (__unused NSException *e) {}
    }
    UIButton *button = Send0(action, @"button");
    if ([button isKindOfClass:[UIButton class]]) {
        NSString *title = [button titleForState:UIControlStateNormal] ?: button.accessibilityLabel;
        if (title.length) return title;
    }
    return nil;
}

+ (void)wrapHandlerOfSheetAction:(id)action before:(void (^)(void))before {
    SEL getter = NSSelectorFromString(@"handler");
    SEL setter = NSSelectorFromString(@"setHandler:");
    if (![action respondsToSelector:getter] || ![action respondsToSelector:setter]) return;
    void (^original)(id) = ((id (*)(id, SEL))objc_msgSend)(action, getter);
    void (^wrapped)(id) = ^(id sender) {
        @try { before(); } @catch (NSException *e) { MTPLog(@"sheet wrapper failed: %@", e); }
        if (original) original(sender);
    };
    ((void (*)(id, SEL, id))objc_msgSend)(action, setter, wrapped);
}

+ (id)makeSheetActionWithTitle:(NSString *)title iconType:(int)iconType handler:(void (^)(void))handler {
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    void (^block)(id) = ^(id sender) { handler(); };
    UIImage *image = nil;
    Class iconClass = NSClassFromString(@"YTIIcon");
    if (iconClass && iconType > 0) {
        id icon = [iconClass new];
        SEL setType = NSSelectorFromString(@"setIconType:");
        SEL imageSel = NSSelectorFromString(@"iconImageWithColor:");
        if ([icon respondsToSelector:setType] && [icon respondsToSelector:imageSel]) {
            ((void (*)(id, SEL, int))objc_msgSend)(icon, setType, iconType);
            image = ((id (*)(id, SEL, id))objc_msgSend)(icon, imageSel, [UIColor labelColor]);
        }
    }
    SEL withIcon = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    SEL plain = NSSelectorFromString(@"actionWithTitle:style:handler:");
    if (image && [actionClass respondsToSelector:withIcon])
        return ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(actionClass, withIcon, title, image, 0, block);
    if ([actionClass respondsToSelector:plain])
        return ((id (*)(id, SEL, id, NSInteger, id))objc_msgSend)(actionClass, plain, title, 0, block);
    return nil;
}

@end

// ---------------------------------------------------------------------------
// Item context extraction
// ---------------------------------------------------------------------------

static void CollectFromNode(id node, NSMutableArray *texts, NSMutableArray *urls, int depth) {
    if (!node || depth > 12) return;
    id attributed = Send0(node, @"attributedText");
    if ([attributed isKindOfClass:[NSAttributedString class]] && [attributed length]) [texts addObject:[attributed string]];
    id url = Send0(node, @"URL");
    if ([url isKindOfClass:[NSURL class]]) [urls addObject:[url absoluteString]];
    NSArray *children = Send0(node, @"subnodes");
    if ([children isKindOfClass:[NSArray class]]) for (id child in children) CollectFromNode(child, texts, urls, depth + 1);
}

static void CollectFromView(UIView *view, NSMutableArray *texts, int depth) {
    if (!view || depth > 10) return;
    if ([view isKindOfClass:[UILabel class]] && [(UILabel *)view text].length) [texts addObject:[(UILabel *)view text]];
    for (UIView *sub in view.subviews) CollectFromView(sub, texts, depth + 1);
}

static void OnVideoID(const char *videoID, void *context) {
    NSMutableArray *ids = (__bridge NSMutableArray *)context;
    [ids addObject:@(videoID)];
}

static MTPItemContext *ContextFromSourceView(UIView *view) {
    MTPItemContext *context = [MTPItemContext new];
    NSMutableArray *texts = [NSMutableArray array];
    NSMutableArray *urls = [NSMutableArray array];
    id cellNode = nil;
    UIView *cellView = nil;
    UIView *current = view;
    for (int i = 0; current && i < 25 && !cellNode && !cellView; i++, current = current.superview) {
        id node = Send0(current, @"asyncdisplaykit_node");
        for (int j = 0; node && j < 25; j++) {
            if ([NSStringFromClass([node class]) rangeOfString:@"CellNode"].location != NSNotFound) { cellNode = node; break; }
            node = Send0(node, @"supernode");
        }
        if (!cellNode && [current isKindOfClass:[UICollectionViewCell class]]) cellView = current;
    }
    if (cellNode) CollectFromNode(cellNode, texts, urls, 0);
    else if (cellView) CollectFromView(cellView, texts, 0);
    context.texts = texts;

    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *url in urls) {
        NSData *bytes = [url dataUsingEncoding:NSUTF8StringEncoding];
        mtp_scan_thumbnail_video_ids(bytes.bytes, bytes.length, OnVideoID, (__bridge void *)ids);
    }
    context.videoID = ids.firstObject;
    for (NSString *text in texts) {
        NSRange dot = [text rangeOfString:@" · "];
        if (dot.location != NSNotFound && dot.location > 0) {
            context.channelName = [text substringToIndex:dot.location];
            break;
        }
    }

    UIViewController *player = gPlayer;
    if (!context.videoID && player.isViewLoaded && view && [view isDescendantOfView:player.view]) {
        context.fromPlayer = YES;
        context.videoID = [MTPContext currentVideoID];
        context.channelID = [MTPContext currentChannelID];
    }
    return context;
}

static const void *kDecoratedKey = &kDecoratedKey;

static void RunDecorators(id sheet, UIView *view) {
    if ([objc_getAssociatedObject(sheet, kDecoratedKey) boolValue]) return; // nested present variants
    objc_setAssociatedObject(sheet, kDecoratedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Cleared after the (possibly nested) present calls finish, so a reused
    // sheet controller is decorated again for its next menu.
    __weak id weakSheet = sheet;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongSheet = weakSheet;
        if (strongSheet) objc_setAssociatedObject(strongSheet, kDecoratedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    NSArray *decorators;
    @synchronized (gDecorators) { decorators = [gDecorators copy]; }
    if (decorators.count == 0) return;
    MTPItemContext *context = ContextFromSourceView(view);
    if ([MTPPrefs boolForKey:MTPKeyDebugLogging]) MTPLog(@"sheet %@ for %@", NSStringFromClass([sheet class]), context);
    for (MTPSheetDecorator decorator in decorators) {
        @try { decorator(sheet, context); } @catch (NSException *e) { MTPLog(@"sheet decorator failed: %@", e); }
    }
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

%group ContextPivot
%hook YTPivotBarViewController
- (void)selectItemWithPivotIdentifier:(NSString *)identifier {
    if ([identifier isKindOfClass:[NSString class]]) gCurrentTab = [identifier copy];
    %orig;
}
%end
%end

%group ContextSectionList
%hook YTSectionListViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gSectionList = self;
    gSurface = ClassifyController(self);
}
%end
%end

%group ContextPlayer
%hook YTPlayerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gPlayer = self;
}
%end
%end

%group ContextElements
%hook YTIElementRenderer
- (NSData *)elementData {
    NSData *data = %orig;
    if (data.length == 0) return data;
    MTPSurface surface = gSurface;
    NSUInteger key = (gFilterGeneration << 4) | (NSUInteger)surface;
    NSNumber *verdict = objc_getAssociatedObject(self, kVerdictKey);
    if (verdict && ([verdict unsignedIntegerValue] >> 1) == key) {
        return ([verdict unsignedIntegerValue] & 1) ? nil : data;
    }
    NSArray *observers, *filters;
    @synchronized (gObservers) { observers = [gObservers copy]; }
    @synchronized (gFilters) { filters = [gFilters copy]; }
    for (MTPElementObserver observer in observers) observer(data, surface);
    BOOL hide = NO;
    for (MTPElementFilter filter in filters) {
        if (filter(data, surface)) { hide = YES; break; }
    }
    objc_setAssociatedObject(self, kVerdictKey, @((key << 1) | (hide ? 1 : 0)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return hide ? nil : data;
}
%end
%end

static void HookSheetPresentation(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return;
    SEL one = NSSelectorFromString(@"presentFromView:");
    if (class_getInstanceMethod(cls, one)) {
        __block void (*orig)(id, SEL, id) = NULL;
        MTPHookMethod(cls, one, imp_implementationWithBlock(^(id self, UIView *view) {
            RunDecorators(self, view);
            orig(self, one, view);
        }), (IMP *)&orig);
    }
    SEL two = NSSelectorFromString(@"presentFromView:completion:");
    if (class_getInstanceMethod(cls, two)) {
        __block void (*orig2)(id, SEL, id, id) = NULL;
        MTPHookMethod(cls, two, imp_implementationWithBlock(^(id self, UIView *view, id completion) {
            RunDecorators(self, view);
            orig2(self, two, view, completion);
        }), (IMP *)&orig2);
    }
    // YouTube 21.4x: -presentFromView:animated:completion:(scrimColor:) (verified in 21.45.4).
    SEL animatedSel = NSSelectorFromString(@"presentFromView:animated:completion:");
    if (class_getInstanceMethod(cls, animatedSel)) {
        __block void (*origAnimated)(id, SEL, id, BOOL, id) = NULL;
        MTPHookMethod(cls, animatedSel, imp_implementationWithBlock(^(id self, UIView *view, BOOL animated, id completion) {
            RunDecorators(self, view);
            origAnimated(self, animatedSel, view, animated, completion);
        }), (IMP *)&origAnimated);
    }
    SEL scrimSel = NSSelectorFromString(@"presentFromView:animated:completion:scrimColor:");
    if (class_getInstanceMethod(cls, scrimSel)) {
        __block void (*origScrim)(id, SEL, id, BOOL, id, id) = NULL;
        MTPHookMethod(cls, scrimSel, imp_implementationWithBlock(^(id self, UIView *view, BOOL animated, id completion, id scrim) {
            RunDecorators(self, view);
            origScrim(self, scrimSel, view, animated, completion, scrim);
        }), (IMP *)&origScrim);
    }
    SEL three = NSSelectorFromString(@"presentFromViewController:animated:completion:");
    if (class_getInstanceMethod(cls, three)) {
        __block void (*orig3)(id, SEL, id, BOOL, id) = NULL;
        MTPHookMethod(cls, three, imp_implementationWithBlock(^(id self, UIViewController *vc, BOOL animated, id completion) {
            RunDecorators(self, nil);
            orig3(self, three, vc, animated, completion);
        }), (IMP *)&orig3);
    }
}

void MTPContextBumpFilterGeneration(void) { gFilterGeneration++; }
void MTPContextSetSurface(MTPSurface surface) { gSurface = surface; }

void MTPInstallContext(void) {
    gFilters = [NSMutableArray array];
    gObservers = [NSMutableArray array];
    gDecorators = [NSMutableArray array];
    NSMutableArray *missing = [NSMutableArray array];
    if (MTPClassWithSelectors(@"YTPivotBarViewController", @[@"selectItemWithPivotIdentifier:"])) { %init(ContextPivot); } else [missing addObject:@"YTPivotBarViewController"];
    if (MTPClassWithSelectors(@"YTSectionListViewController", @[@"viewDidAppear:"])) { %init(ContextSectionList); } else [missing addObject:@"YTSectionListViewController"];
    if (MTPClassWithSelectors(@"YTPlayerViewController", @[@"viewDidAppear:"])) { %init(ContextPlayer); } else [missing addObject:@"YTPlayerViewController"];
    if (MTPClassWithSelectors(@"YTIElementRenderer", @[@"elementData"])) { %init(ContextElements); } else [missing addObject:@"YTIElementRenderer.elementData"];
    HookSheetPresentation(@"YTDefaultSheetController");
    HookSheetPresentation(@"YTActionSheetController");
    [[NSNotificationCenter defaultCenter] addObserverForName:MTPPrefsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        gFilterGeneration++;
    }];
    if (missing.count) MTPLog(@"context: missing hook targets %@", missing);
}
