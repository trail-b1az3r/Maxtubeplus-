# Floating menu, YTPlus dock customization and the Subscriptions tab

This note covers why YTPlus loses dock customization and the Subscriptions tab when YouTube shows its newer floating menu, and how MaxTubePlus fixes it without spoofing iOS 17.

## What was inspected

| Source | What it showed |
|---|---|
| **YTPlus 6.0b2** binary (`com.dvntm.ytlite_6.0b2_iphoneos-arm.deb`, the default `tweak_version` in MaxTube). I read its Objective-C metadata with `otool -oV` and resolved the selector references with `scripts`-style Mach-O parsing. | The tab logic lives in the class methods `+[YTPTabHelper applyCustomTabsToPivotBarRenderer:]`, `+applyCustomTabsToGuideResponse:`, `+selectStartupTabInPivotBar:` and `+applyStartupTabInPivotBar:`. The editor is `TabbarVC`, which has `_activeTabs`, `_inactiveTabs` and `saveTabsOrder`. Glass styling is in `YTPLiquidGlass`, which has `layoutTabBarInPivotBar:` and `restyleBackgroundOfPivotBar:`. There is also a `cairo` flag that is read from `crossPlatformCoreClientGlobalConfigEnableCairoRefresh` (`updateCairoWithPivotRenderer:`). Re-checked against **YTPlus 6.0** (now MaxTube's default): `YTPTabHelper` still has the same class methods, `TabbarVC`, `YTPLiquidGlass` and `YTPPivotTabBarController` are unchanged, so the compatibility layer applies unchanged. The hooked YouTube class names are encrypted strings in the binary, so the hook sites cannot be listed statically. The only pivot view type that appears in plain text is `YTPivotBarView`. |
| **YTLite** open-source history (`dayanch96/YTLite`) | The classic implementation hooks `-[YTPivotBarView setRenderer:]` and edits `renderer.itemsArray`, removing items by `pivotIdentifier`. It inserts items with `+[YTIPivotBarRenderer pivotSupportedRenderersWithBrowseId:title:iconType:]`. |
| **YouTubeHeader** (PoomSmart, current) | `YTIGuideResponse` has `itemsArray`, and each item has a `pivotBarRenderer`. `YTIcon` has separate Cairo icons, for example `YT_TAB_SUBSCRIPTIONS_CAIRO = 1155` next to `YT_TAB_SUBSCRIPTIONS = 66`. None of the public headers declare a floating-bar view class. |
| **YouTube's redesign (Oct–Nov 2026)** | YouTube moved Subscriptions out of the bottom bar and into a top bar on Home. The new bar has four items (Home, Shorts, Create, You) and is drawn with a floating, liquid-glass treatment. Sources: [9to5Google](https://9to5google.com/2026/10/22/youtube-subscriptions-android-ios/), [9to5Google](https://9to5google.com/2026/11/05/youtube-app-redesign-subscriptions-tab/). YTPlus 6.0 release notes say it was "adapted for YouTube 21.43 … floating tab bar". |

## Root cause

1. **Different consumer.** In floating mode the pivot data is not delivered through `-[YTPivotBarView setRenderer:]`. YTPlus 6.0b2 applies its tab customization from that classic path, so in floating mode its logic, and with it the user's dock settings, never runs.
2. **Data, not view.** The server no longer sends `FEsubscriptions` in the pivot renderer for the redesigned UI. Hiding or re-showing a view cannot bring the tab back because it isn't in the data. It has to be re-created as a pivot item.
3. **Why spoofing iOS 17 "works".** The floating, liquid-glass bar is only used on iOS 26 clients. Reporting iOS 17 sends YouTube back to the classic bar and the classic guide response, so both problems disappear. The cost is losing the new UI and changing every other version-gated behavior, which is why it is not used.

The likely causes split as follows:
- **Architecture:** a different consumer, confirmed.
- **Feature flag:** the Cairo/redesign experiment, confirmed via YTPlus's `cairoFromColdConfig`.
- **Server-side tab registration:** Subscriptions is missing from the data, confirmed by the published redesign.
- **Not selector renames:** `YTPivotBarView`, `YTIPivotBarRenderer`, `pivotIdentifier` and the factory still exist in current headers.

## The compatibility layer (`MaxTubePlus/ModernUI`)

- `MTPTabLayout` works on the **`YTIPivotBarRenderer` data**, so it works for whichever view displays it:
  1. reads the server tabs by `pivotIdentifier`;
  2. re-creates `FEsubscriptions` with YouTube's own factory, using the Cairo icon if the other items use Cairo icons. It is placed before *You*, as in the classic layout, and only if the user has not hidden it. YTPlus's legacy `removeSubscriptions` is respected;
  3. applies the MaxTubePlus order and hidden list. This is only a fallback for when YTPlus's helper is missing;
  4. **calls `+[YTPTabHelper applyCustomTabsToPivotBarRenderer:]`** on the same renderer, so the user's existing YTPlus tab editor settings stay authoritative. Nothing is duplicated.
  The pass is idempotent per renderer and per preferences generation, and it never drops items it cannot identify.
- **Hooks:**
  - The classic `-[YTPivotBarView setRenderer:]`.
  - Floating-mode consumers found at launch by a guarded runtime scan. It looks at classes in YouTube's own images (not injected dylibs), Objective-C or Swift, whose names contain `PivotBar`, `TabBar` or `Guide`. It hooks single-object setters (`setRenderer:`, `setPivotBarRenderer:`, `setGuideResponse:`, …) and only acts when the argument is actually a `YTIPivotBarRenderer` or `YTIGuideResponse`. Every hooked consumer is logged and listed under Settings › MaxTubePlus › Modern UI Compatibility › Hooks.
- **No spoofing.** MaxTubePlus never touches `UIDevice` or `systemVersion`. It detects a spoof (`UIDevice.systemVersion` vs `NSProcessInfo.operatingSystemVersion`) and reports it in settings.
- **Persistence:** YTPlus keeps its own settings in `com.dvntm.ytlite`. MaxTubePlus settings are in `com.maxtubeplus.prefs`.

## Known limits (honest)

- The exact class that feeds the floating bar in 21.42.4 was not confirmed against the 21.42.4 binary. The decrypted app is proprietary and was not available to this project. The runtime scan is the safeguard, and the settings page shows whether a floating consumer was actually seen. If none is listed on a device, the floating bar is fed some other way, and `MTPTabLayout` needs a new hook point. That is a small, local change.
- YTPlus 6.0 (final) changed its internals for 21.43. MaxTubePlus calls `YTPTabHelper` only when it exists, and otherwise falls back to its own dock editor.
- Whether the server still serves the `FEsubscriptions` browse feed to redesigned clients can only be confirmed on a device. The browse endpoint is the same one the Subscriptions chip on Home opens.
