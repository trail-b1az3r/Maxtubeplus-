// Shared Objective-C infrastructure for MaxTubePlus modules.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../Core/MTPCore.h"

NS_ASSUME_NONNULL_BEGIN

#define MTP_TARGET_YT_VERSION @"21.42.4"
#define MTP_MINIMUM_YT_VERSION @"21.30.0"
#define MTP_BUNDLE_ID @"com.google.ios.youtube"

#ifndef MTP_VERSION
#define MTP_VERSION "0.0.0"
#endif

void MTPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Keys owned by MaxTubePlus (suite `com.maxtubeplus.prefs`).
extern NSString *const MTPKeyDownloadsEnabled;        // BOOL
extern NSString *const MTPKeyDownloadsQuality;        // NSInteger max height (0 = best)
extern NSString *const MTPKeyDownloadsAudioOnly;      // BOOL
extern NSString *const MTPKeyDownloadsCellular;       // BOOL
extern NSString *const MTPKeyDownloadsNotifications;  // BOOL
extern NSString *const MTPKeyDownloadsMaxConcurrent;  // NSInteger
extern NSString *const MTPKeyDownloadsMaxRetries;     // NSInteger

extern NSString *const MTPKeyDeArrowTitles;           // BOOL
extern NSString *const MTPKeyDeArrowThumbnails;       // BOOL

extern NSString *const MTPKeyHighRefreshEnabled;      // BOOL

extern NSString *const MTPKeySuppressionAuto;         // BOOL
extern NSString *const MTPKeySuppressionThreshold;    // NSInteger
extern NSString *const MTPKeySuppressionWindowDays;   // NSInteger (0 = never decays)

extern NSString *const MTPKeySearchFiltersEnabled;    // BOOL
extern NSString *const MTPKeySearchFetchLikes;        // BOOL (uses RYD API for like counts)
extern NSString *const MTPKeySearchReplaceYouTubeFilters; // BOOL
extern NSString *const MTPKeySearchSortMode;          // NSInteger MTPSortMode
extern NSString *const MTPKeySearchFilterState;       // NSDictionary

extern NSString *const MTPKeyModernUICompat;          // BOOL
extern NSString *const MTPKeyRestoreSubscriptions;    // BOOL
extern NSString *const MTPKeyTabOrder;                // NSArray<NSString *>
extern NSString *const MTPKeyHiddenTabs;              // NSArray<NSString *>

extern NSString *const MTPKeyForceUnverifiedVersion;  // BOOL
extern NSString *const MTPKeyDebugLogging;            // BOOL

extern NSNotificationName const MTPPrefsChangedNotification;

@interface MTPPrefs : NSObject
+ (NSUserDefaults *)defaults;
+ (BOOL)boolForKey:(NSString *)key;
+ (NSInteger)integerForKey:(NSString *)key;
+ (nullable id)objectForKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key;
+ (void)setObject:(nullable id)value forKey:(NSString *)key;
+ (void)resetAll;

/// Read-only access to YTPlus/YTLite preferences (suite `com.dvntm.ytlite`).
/// MaxTubePlus never writes YTPlus keys except where it is explicitly
/// mirroring a user change made from the YTPlus-compatible UI.
+ (NSUserDefaults *)ytplusDefaults;
+ (BOOL)ytplusBool:(NSString *)key;
@end

typedef NS_ENUM(NSInteger, MTPModule) {
    MTPModuleDownloads = 0,
    MTPModuleDeArrow,
    MTPModuleRefreshRate,
    MTPModuleSuppression,
    MTPModuleSearch,
    MTPModuleModernUI,
    MTPModuleSettings,
    MTPModuleCount,
};

/// Runtime compatibility information for the running YouTube build.
@interface MTPCompat : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly, copy) NSString *appVersion;
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly) MTPCompatLevel level;
/// UIDevice.systemVersion (may be spoofed by YTPlus/other tweaks).
@property (nonatomic, readonly, copy) NSString *reportedSystemVersion;
/// NSProcessInfo.operatingSystemVersion (kernel-provided, not spoofable via UIDevice hooks).
@property (nonatomic, readonly, copy) NSString *realSystemVersion;
@property (nonatomic, readonly) BOOL systemVersionSpoofed;
@property (nonatomic, readonly) BOOL ytplusLoaded;
@property (nonatomic, readonly) BOOL proMotionDisplay;
/// Whether hooks for a module may be installed in this build.
- (BOOL)mayInstallModule:(MTPModule)module;
/// Records whether a module's hooks actually found their targets.
- (void)setStatus:(NSString *)status forModule:(MTPModule)module;
- (NSString *)statusForModule:(MTPModule)module;
- (NSString *)summary;
@end

/// Replaces an instance method using only the Objective-C runtime (no Cydia
/// Substrate dependency, so the dylib loads in any injector). If the method is
/// inherited, an override is added to `cls` that forwards to the inherited
/// implementation. Returns NO (and changes nothing) if the selector is not
/// implemented anywhere in the hierarchy.
BOOL MTPHookMethod(Class cls, SEL selector, IMP replacement, IMP _Nullable *_Nonnull original);

/// Returns an Objective-C class only if it exists *and* responds to all the
/// listed instance selectors. Used to fail safely on changed YouTube builds.
Class _Nullable MTPClassWithSelectors(NSString *className, NSArray<NSString *> *selectors);

/// Walks the responder/view-controller hierarchy and returns class names.
NSString *MTPResponderChainDescription(id _Nullable responder);

UIViewController *_Nullable MTPTopViewController(void);
void MTPToast(NSString *message);

NS_ASSUME_NONNULL_END
