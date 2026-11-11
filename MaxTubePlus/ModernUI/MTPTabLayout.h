#import "../Common/MTPCommon.h"

NS_ASSUME_NONNULL_BEGIN

/// Dock (pivot bar) compatibility layer for YouTube's floating-menu UI.
///
/// Root cause (see docs/MODERN_UI_INVESTIGATION.md):
///  * With the floating ("Cairo"/liquid-glass) navigation, the server sends a
///    pivot-bar renderer WITHOUT FEsubscriptions (Subscriptions moved to a
///    chip row on Home), so there is nothing for YTPlus to show or reorder.
///  * The floating bar is fed by a different consumer than the classic
///    YTPivotBarView, so YTPlus's pivot hook - which ends in
///    +[YTPTabHelper applyCustomTabsToPivotBarRenderer:] - never sees it.
///  * Spoofing iOS 17 hides both problems only because it makes YouTube fall
///    back to the classic bar and classic guide response.
///
/// This class mutates the YTIPivotBarRenderer *data* (not the view) so it
/// works for whichever view consumes it, then hands the same renderer to
/// YTPlus's own tab helper so YTPlus's existing settings stay authoritative.
@interface MTPTabLayout : NSObject

+ (instancetype)shared;

/// Applies MaxTubePlus arrangement + Subscriptions restore, then (optionally)
/// YTPlus's own customisation. Idempotent for a given renderer.
- (void)applyToPivotBarRenderer:(id)renderer source:(NSString *)source applyYTPlus:(BOOL)applyYTPlus;

/// Same, for a YTIGuideResponse (walks its pivotBarRenderer items).
- (void)applyToGuideResponse:(id)guideResponse source:(NSString *)source;

/// Whether YTPlus's tab helper class is present in this process.
@property (nonatomic, readonly) BOOL ytplusTabHelperAvailable;
/// Diagnostics shown in settings.
@property (nonatomic, readonly, copy) NSArray<NSString *> *lastServerTabs;
@property (nonatomic, readonly, copy) NSArray<NSString *> *lastFinalTabs;
@property (nonatomic, readonly, copy) NSString *lastConsumer;
@property (nonatomic, readonly) BOOL floatingConsumerSeen;
@property (nonatomic, readonly) BOOL subscriptionsInjected;
@property (nonatomic, readonly) NSUInteger applicationCount;

/// Known tab identifiers for the fallback editor.
+ (NSArray<NSString *> *)knownTabIdentifiers;
+ (NSString *)displayNameForIdentifier:(NSString *)identifier;

/// Ask YouTube to rebuild the pivot bar after a preference change.
- (void)requestRefresh;

@end

NS_ASSUME_NONNULL_END
