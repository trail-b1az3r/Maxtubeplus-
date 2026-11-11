#import "MTPCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>

NSString *const MTPKeyDownloadsEnabled = @"downloads.enabled";
NSString *const MTPKeyDownloadsQuality = @"downloads.maxHeight";
NSString *const MTPKeyDownloadsAudioOnly = @"downloads.audioOnly";
NSString *const MTPKeyDownloadsCellular = @"downloads.allowCellular";
NSString *const MTPKeyDownloadsNotifications = @"downloads.notifications";
NSString *const MTPKeyDownloadsMaxConcurrent = @"downloads.maxConcurrent";
NSString *const MTPKeyDownloadsMaxRetries = @"downloads.maxRetries";

NSString *const MTPKeyDeArrowTitles = @"dearrow.titles";
NSString *const MTPKeyDeArrowThumbnails = @"dearrow.thumbnails";

NSString *const MTPKeyHighRefreshEnabled = @"refresh.high";

NSString *const MTPKeySuppressionAuto = @"suppression.auto";
NSString *const MTPKeySuppressionThreshold = @"suppression.threshold";
NSString *const MTPKeySuppressionWindowDays = @"suppression.windowDays";

NSString *const MTPKeySearchFiltersEnabled = @"search.filters";
NSString *const MTPKeySearchFetchLikes = @"search.fetchLikes";
NSString *const MTPKeySearchSortMode = @"search.sortMode";
NSString *const MTPKeySearchFilterState = @"search.filterState";

NSString *const MTPKeyModernUICompat = @"modernui.enabled";
NSString *const MTPKeyRestoreSubscriptions = @"modernui.restoreSubscriptions";
NSString *const MTPKeyTabOrder = @"modernui.tabOrder";
NSString *const MTPKeyHiddenTabs = @"modernui.hiddenTabs";

NSString *const MTPKeyForceUnverifiedVersion = @"general.forceUnverified";
NSString *const MTPKeyDebugLogging = @"general.debugLogging";

NSNotificationName const MTPPrefsChangedNotification = @"MTPPrefsChangedNotification";

static NSString *const kSuiteName = @"com.maxtubeplus.prefs";
static NSString *const kYTPlusSuiteName = @"com.dvntm.ytlite";

void MTPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.maxtubeplus", "tweak"); });
    os_log(logger, "[MaxTubePlus] %{public}@", message);
}

@implementation MTPPrefs

+ (NSUserDefaults *)defaults {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        [defaults registerDefaults:@{
            MTPKeyDownloadsEnabled: @YES,
            MTPKeyDownloadsQuality: @1080,
            MTPKeyDownloadsAudioOnly: @NO,
            MTPKeyDownloadsCellular: @NO,
            MTPKeyDownloadsNotifications: @YES,
            MTPKeyDownloadsMaxConcurrent: @2,
            MTPKeyDownloadsMaxRetries: @5,
            MTPKeyDeArrowTitles: @YES,
            MTPKeyDeArrowThumbnails: @YES,
            MTPKeyHighRefreshEnabled: @YES,
            MTPKeySuppressionAuto: @YES,
            MTPKeySuppressionThreshold: @3,
            MTPKeySuppressionWindowDays: @60,
            MTPKeySearchFiltersEnabled: @YES,
            MTPKeySearchFetchLikes: @YES,
            MTPKeySearchSortMode: @0,
            // Default configuration required by the project: newer floating
            // menu, no iOS 17 spoof, dock customisation + Subscriptions on.
            MTPKeyModernUICompat: @YES,
            MTPKeyRestoreSubscriptions: @YES,
            MTPKeyTabOrder: @[],
            MTPKeyHiddenTabs: @[],
            MTPKeyForceUnverifiedVersion: @NO,
            MTPKeyDebugLogging: @NO,
        }];
    });
    return defaults;
}

+ (BOOL)boolForKey:(NSString *)key { return [[self defaults] boolForKey:key]; }
+ (NSInteger)integerForKey:(NSString *)key { return [[self defaults] integerForKey:key]; }
+ (id)objectForKey:(NSString *)key { return [[self defaults] objectForKey:key]; }

+ (void)changed:(NSString *)key {
    [[NSNotificationCenter defaultCenter] postNotificationName:MTPPrefsChangedNotification object:nil userInfo:@{@"key": key}];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key { [[self defaults] setBool:value forKey:key]; [self changed:key]; }
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key { [[self defaults] setInteger:value forKey:key]; [self changed:key]; }
+ (void)setObject:(id)value forKey:(NSString *)key {
    if (value) [[self defaults] setObject:value forKey:key];
    else [[self defaults] removeObjectForKey:key];
    [self changed:key];
}

+ (void)resetAll {
    [[self defaults] removePersistentDomainForName:kSuiteName];
    [self changed:@"*"];
}

+ (NSUserDefaults *)ytplusDefaults {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:kYTPlusSuiteName]; });
    return defaults;
}

+ (BOOL)ytplusBool:(NSString *)key { return [[self ytplusDefaults] boolForKey:key]; }

@end

@implementation MTPCompat {
    NSMutableDictionary<NSNumber *, NSString *> *_status;
}

+ (instancetype)shared {
    static MTPCompat *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *info = [NSBundle mainBundle].infoDictionary;
        _appVersion = [info[@"CFBundleShortVersionString"] copy] ?: @"";
        _bundleIdentifier = [NSBundle mainBundle].bundleIdentifier ?: @"";
        _level = mtp_compat_level(_appVersion.UTF8String, MTP_TARGET_YT_VERSION.UTF8String, MTP_MINIMUM_YT_VERSION.UTF8String);
        NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
        _realSystemVersion = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
        _reportedSystemVersion = [UIDevice currentDevice].systemVersion ?: @"";
        // A spoof (e.g. "iOS 17" to get the old navigation) only differs in
        // the major component; patch formatting differences are not spoofs.
        _systemVersionSpoofed = [_reportedSystemVersion integerValue] != v.majorVersion;
        _ytplusLoaded = objc_getClass("YTLUserDefaults") != Nil || dlopen("YTLite.dylib", RTLD_NOLOAD) != NULL
            || [[NSFileManager defaultManager] fileExistsAtPath:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Frameworks/YTLite.dylib"]];
        _proMotionDisplay = [UIScreen mainScreen].maximumFramesPerSecond > 60;
        _status = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)mayInstallModule:(MTPModule)module {
    if (module == MTPModuleSettings) return YES; // Always reachable so the user can see status.
    switch (_level) {
        case MTPCompatVerified:
        case MTPCompatSameMajor:
            return YES;
        case MTPCompatUnknown:
        case MTPCompatUnsupported:
        default:
            return [MTPPrefs boolForKey:MTPKeyForceUnverifiedVersion];
    }
}

- (void)setStatus:(NSString *)status forModule:(MTPModule)module {
    @synchronized (self) { _status[@(module)] = status; }
    MTPLog(@"module %ld: %@", (long)module, status);
}

- (NSString *)statusForModule:(MTPModule)module {
    @synchronized (self) { return _status[@(module)] ?: @"Not loaded"; }
}

- (NSString *)levelDescription {
    switch (_level) {
        case MTPCompatVerified: return @"verified target";
        case MTPCompatSameMajor: return @"same release train (hooks individually guarded)";
        case MTPCompatUnsupported: return @"unsupported (modules disabled)";
        default: return @"unknown (modules disabled)";
    }
}

- (NSString *)summary {
    return [NSString stringWithFormat:@"YouTube %@ (%@) — %@\niOS %@ (reported %@%@)\nYTPlus loaded: %@ · ProMotion: %@",
        _appVersion, _bundleIdentifier, [self levelDescription], _realSystemVersion, _reportedSystemVersion,
        _systemVersionSpoofed ? @", SPOOFED" : @"", _ytplusLoaded ? @"yes" : @"no", _proMotionDisplay ? @"yes" : @"no"];
}

@end

Class MTPClassWithSelectors(NSString *className, NSArray<NSString *> *selectors) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        MTPLog(@"compat: class %@ missing", className);
        return Nil;
    }
    for (NSString *sel in selectors) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(sel)]) {
            MTPLog(@"compat: %@ lacks -%@", className, sel);
            return Nil;
        }
    }
    return cls;
}

NSString *MTPResponderChainDescription(id responder) {
    NSMutableArray *names = [NSMutableArray array];
    id current = responder;
    for (int depth = 0; current && depth < 32; depth++) {
        [names addObject:NSStringFromClass([current class])];
        if ([current isKindOfClass:[UIResponder class]]) current = [current nextResponder];
        else if ([current respondsToSelector:@selector(parentResponder)]) current = [current performSelector:@selector(parentResponder)];
        else break;
    }
    return [names componentsJoinedByString:@">"];
}

UIViewController *MTPTopViewController(void) {
    Class utils = NSClassFromString(@"YTUIUtils");
    if ([utils respondsToSelector:@selector(topViewControllerForPresenting)]) {
        UIViewController *vc = [utils performSelector:@selector(topViewControllerForPresenting)];
        if (vc) return vc;
    }
    UIWindow *window = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window = w; break; }
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

void MTPToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class toast = NSClassFromString(@"YTToastResponderEvent");
        UIViewController *top = MTPTopViewController();
        if ([toast respondsToSelector:@selector(eventWithMessage:firstResponder:)] && top) {
            id event = ((id (*)(id, SEL, id, id))objc_msgSend)(toast, @selector(eventWithMessage:firstResponder:), message, top);
            if ([event respondsToSelector:@selector(send)]) { [event performSelector:@selector(send)]; return; }
        }
        MTPLog(@"toast: %@", message);
    });
}
