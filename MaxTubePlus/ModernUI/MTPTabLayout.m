#import "MTPTabLayout.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kSubscriptions = @"FEsubscriptions";
static const void *kAppliedKey = &kAppliedKey;

// Icon types from YouTubeHeader's YTIcon.h.
static const int kIconSubscriptions = 66;        // YT_TAB_SUBSCRIPTIONS
static const int kIconSubscriptionsCairo = 1155; // YT_TAB_SUBSCRIPTIONS_CAIRO

static id MTPSend(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *IdentifierOfItem(id supported) {
    for (NSString *getter in @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer"]) {
        // GPB "has" accessors avoid auto-creating empty sub-messages.
        NSString *hasSel = [@"has" stringByAppendingString:[[getter substringToIndex:1].uppercaseString stringByAppendingString:[getter substringFromIndex:1]]];
        if ([supported respondsToSelector:NSSelectorFromString(hasSel)] &&
            !((BOOL (*)(id, SEL))objc_msgSend)(supported, NSSelectorFromString(hasSel))) continue;
        NSString *identifier = MTPSend(MTPSend(supported, getter), @"pivotIdentifier");
        if ([identifier isKindOfClass:[NSString class]] && identifier.length) return identifier;
    }
    return nil;
}

static int IconTypeOfItem(id supported) {
    id item = MTPSend(supported, @"pivotBarItemRenderer");
    id icon = MTPSend(item, @"icon");
    if (icon && [icon respondsToSelector:NSSelectorFromString(@"iconType")])
        return ((int (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"iconType"));
    return 0;
}

static void FillList(MTPTabList *list, NSArray<NSString *> *identifiers) {
    mtp_tabs_init(list);
    for (NSString *identifier in identifiers) {
        if ([identifier isKindOfClass:[NSString class]]) mtp_tabs_append(list, identifier.UTF8String);
    }
}

@implementation MTPTabLayout {
    NSUInteger _generation;
}

+ (instancetype)shared {
    static MTPTabLayout *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _generation = 1;
        _lastServerTabs = @[];
        _lastFinalTabs = @[];
        _lastConsumer = @"none yet";
        [[NSNotificationCenter defaultCenter] addObserverForName:MTPPrefsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSString *key = note.userInfo[@"key"];
            if ([key hasPrefix:@"modernui."] || [key isEqualToString:@"*"]) self->_generation++;
        }];
    }
    return self;
}

- (BOOL)ytplusTabHelperAvailable {
    Class helper = NSClassFromString(@"YTPTabHelper");
    return helper && [helper respondsToSelector:NSSelectorFromString(@"applyCustomTabsToPivotBarRenderer:")];
}

+ (NSArray<NSString *> *)knownTabIdentifiers {
    return @[@"FEwhat_to_watch", @"FEshorts", @"FEuploads", kSubscriptions, @"FElibrary", @"FEexplore", @"FEhistory"];
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier {
    NSDictionary *names = @{
        @"FEwhat_to_watch": @"Home", @"FEshorts": @"Shorts", @"FEuploads": @"Create",
        kSubscriptions: @"Subscriptions", @"FElibrary": @"You", @"FEexplore": @"Explore",
        @"FEhistory": @"History", @"FEdownloads": @"Downloads",
    };
    return names[identifier] ?: identifier;
}

- (BOOL)subscriptionsWanted {
    if (![MTPPrefs boolForKey:MTPKeyModernUICompat]) return NO;
    if (![MTPPrefs boolForKey:MTPKeyRestoreSubscriptions]) return NO;
    NSArray *hidden = [MTPPrefs objectForKey:MTPKeyHiddenTabs];
    if ([hidden containsObject:kSubscriptions]) return NO;
    // Respect YTPlus's legacy "hide Subscriptions tab" switch.
    if ([MTPPrefs ytplusBool:@"removeSubscriptions"]) return NO;
    return YES;
}

- (NSArray<NSString *> *)hiddenIdentifiers:(BOOL)ytplusWillApply {
    NSMutableArray *hidden = [NSMutableArray arrayWithArray:[MTPPrefs objectForKey:MTPKeyHiddenTabs] ?: @[]];
    if (!ytplusWillApply) {
        // YTPlus/YTLite legacy keys (pre-6.0 tab switches) for setups where
        // YTPlus's helper is not present to apply them itself.
        NSDictionary *legacy = @{@"removeShorts": @"FEshorts", @"removeSubscriptions": kSubscriptions,
                                 @"removeLibrary": @"FElibrary", @"removeUploads": @"FEuploads"};
        [legacy enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *identifier, BOOL *stop) {
            if ([MTPPrefs ytplusBool:key]) [hidden addObject:identifier];
        }];
    }
    return hidden;
}

- (id)makeSubscriptionsItemLike:(NSArray *)items {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (![rendererClass respondsToSelector:factory]) {
        MTPLog(@"modernui: YTIPivotBarRenderer factory missing; cannot restore Subscriptions");
        return nil;
    }
    BOOL cairo = NO;
    for (id item in items) if (IconTypeOfItem(item) >= 1000) { cairo = YES; break; }
    NSString *title = [[NSBundle mainBundle] localizedStringForKey:@"subscriptions.title" value:@"Subscriptions" table:nil];
    return ((id (*)(id, SEL, id, id, int))objc_msgSend)(rendererClass, factory, kSubscriptions, title,
                                                       cairo ? kIconSubscriptionsCairo : kIconSubscriptions);
}

- (void)applyToPivotBarRenderer:(id)renderer source:(NSString *)source applyYTPlus:(BOOL)applyYTPlus {
    if (!renderer || ![MTPPrefs boolForKey:MTPKeyModernUICompat]) return;
    NSMutableArray *items = MTPSend(renderer, @"itemsArray");
    if (![items isKindOfClass:[NSMutableArray class]] || items.count == 0) return;

    NSNumber *applied = objc_getAssociatedObject(renderer, kAppliedKey);
    if (applied.unsignedIntegerValue == _generation) return;

    @try {
        NSMutableArray<NSString *> *serverIDs = [NSMutableArray array];
        NSMutableDictionary<NSString *, id> *byID = [NSMutableDictionary dictionary];
        NSMutableArray *unidentified = [NSMutableArray array];
        for (id item in items) {
            NSString *identifier = IdentifierOfItem(item);
            if (identifier && !byID[identifier]) {
                [serverIDs addObject:identifier];
                byID[identifier] = item;
            } else {
                [unidentified addObject:item];
            }
        }

        BOOL ytplusWillApply = applyYTPlus && self.ytplusTabHelperAvailable;
        BOOL wantSubs = [self subscriptionsWanted];
        NSArray *userOrder = [MTPPrefs objectForKey:MTPKeyTabOrder] ?: @[];
        NSMutableArray *order = [userOrder mutableCopy];
        if (order.count == 0 && wantSubs && !byID[kSubscriptions]) {
            // Classic placement: before "You"/Library, otherwise at the end.
            order = [serverIDs mutableCopy];
            NSUInteger libraryIndex = [order indexOfObject:@"FElibrary"];
            [order insertObject:kSubscriptions atIndex:libraryIndex == NSNotFound ? order.count : libraryIndex];
        }

        MTPTabList present, orderList, hiddenList, injectList, result;
        FillList(&present, serverIDs);
        FillList(&orderList, order);
        FillList(&hiddenList, [self hiddenIdentifiers:ytplusWillApply]);
        FillList(&injectList, wantSubs ? @[kSubscriptions] : @[]);
        mtp_tabs_arrange(&present, &orderList, &hiddenList, &injectList, &result);

        NSMutableArray *newItems = [NSMutableArray array];
        NSMutableArray<NSString *> *finalIDs = [NSMutableArray array];
        BOOL injected = NO;
        for (size_t i = 0; i < result.count; i++) {
            NSString *identifier = @(result.identifiers[i]);
            id item = byID[identifier];
            if (!item && [identifier isEqualToString:kSubscriptions]) {
                item = [self makeSubscriptionsItemLike:items];
                injected = item != nil;
            }
            if (item) {
                [newItems addObject:item];
                [finalIDs addObject:identifier];
            }
        }
        // Items we could not identify are kept (never silently dropped).
        [newItems addObjectsFromArray:unidentified];

        if (newItems.count > 0) {
            [items removeAllObjects];
            [items addObjectsFromArray:newItems];
        }

        if (ytplusWillApply) {
            // Mark first so a re-entrant call from YTPlus's own hooks is a no-op.
            objc_setAssociatedObject(renderer, kAppliedKey, @(_generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            Class helper = NSClassFromString(@"YTPTabHelper");
            ((void (*)(id, SEL, id))objc_msgSend)(helper, NSSelectorFromString(@"applyCustomTabsToPivotBarRenderer:"), renderer);
            NSMutableArray *afterYTPlus = [NSMutableArray array];
            for (id item in items) {
                NSString *identifier = IdentifierOfItem(item);
                if (identifier) [afterYTPlus addObject:identifier];
            }
            finalIDs = afterYTPlus;
        }

        objc_setAssociatedObject(renderer, kAppliedKey, @(_generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized (self) {
            _lastServerTabs = [serverIDs copy];
            _lastFinalTabs = [finalIDs copy];
            _lastConsumer = [source copy];
            _subscriptionsInjected = injected || (_subscriptionsInjected && [finalIDs containsObject:kSubscriptions]);
            if (![source isEqualToString:@"YTPivotBarView"]) _floatingConsumerSeen = YES;
            _applicationCount++;
        }
        if ([MTPPrefs boolForKey:MTPKeyDebugLogging])
            MTPLog(@"modernui[%@]: server=%@ final=%@ ytplus=%d", source, serverIDs, finalIDs, ytplusWillApply);
    } @catch (NSException *exception) {
        MTPLog(@"modernui: exception while arranging tabs: %@", exception);
    }
}

- (void)applyToGuideResponse:(id)guideResponse source:(NSString *)source {
    NSArray *items = MTPSend(guideResponse, @"itemsArray");
    if (![items isKindOfClass:[NSArray class]]) return;
    for (id supported in items) {
        SEL has = NSSelectorFromString(@"hasPivotBarRenderer");
        if ([supported respondsToSelector:has] && !((BOOL (*)(id, SEL))objc_msgSend)(supported, has)) continue;
        id pivot = MTPSend(supported, @"pivotBarRenderer");
        if (pivot) [self applyToPivotBarRenderer:pivot source:source applyYTPlus:YES];
    }
}

- (void)requestRefresh {
    _generation++;
    dispatch_async(dispatch_get_main_queue(), ^{
        Class combo = NSClassFromString(@"YTHeaderContentComboViewController");
        SEL refresh = NSSelectorFromString(@"refreshPivotBar");
        if ([combo instancesRespondToSelector:refresh]) {
            id controller = [[combo alloc] init];
            ((void (*)(id, SEL))objc_msgSend)(controller, refresh);
        } else {
            MTPToast(@"Restart YouTube to apply dock changes.");
        }
    });
}

@end
