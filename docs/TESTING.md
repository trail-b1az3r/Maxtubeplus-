# MaxTubePlus testing

This page separates what has been **verified** from what still **requires a device**. Nothing here claims device results that were not obtained.

## Verified (automated, reproducible)

| Check | How | Where |
|---|---|---|
| Core logic: version gating, duration/count/age parsing, filter combinations and individual removal, recency/relevance sort, suppression threshold (min 2, decay, auto-off), surfaces where suppression is allowed, DeArrow title formatting, dock arrangement (Subscriptions injection, hiding, ordering, never empty), search `sp` encoding against known YouTube values (`EgIQAQ==`, `CAI=`), protobuf exact-string matching, thumbnail video-ID extraction, retry back-off, format picking | `Tests/run_tests.sh`, 122 checks, built with ASan and UBSan | CI `checks` job and locally |
| IPA tooling: bundle/version/decryption gate, Info.plist patch (idempotent, keeps binary format), and **failure when a bundled dylib is not loaded** (no silently skipped tweaks) | `Tests/test_ipa_tool.py` with synthetic IPAs and fat/thin Mach-O | CI and locally |
| Static checks: Logos `%hook/%group`/`%end` balance, every source listed in the Makefile, every module installer defined and called, no signing material or binaries committed, workflow YAML parses | `scripts/static_checks.sh` | CI and locally |
| The tweak compiles and links with `-Wall -Werror` (arm64, iOS 15 target, iPhoneOS 16.5 SDK) | Theos + L1ghtmann iOS toolchain on Linux (local and CI); Theos + Xcode on macOS (CI) | `maxtubeplus_ci.yml` |
| Live third-party APIs return the shapes the parsers expect | `curl` against DeArrow branding, the DeArrow thumbnail service, YouTube oEmbed and the RYD votes API (2026-11-11) | manual |
| YTPlus 6.0b2 internals used by the dock layer (`YTPTabHelper` class methods) | `otool -oV` plus selector-reference resolution on the shipped dylib | manual (see MODERN_UI_INVESTIGATION.md) |

## Not verified: requires YouTube 21.42.4 on a device

A decrypted 21.42.4 IPA is proprietary and was not available to this project. A packaged IPA was therefore **not** produced or run here. Every item below needs a device run. Settings › MaxTubePlus shows live status for each module to help with this. Turn on *General › Debug logging* and read Console with the filter `com.maxtubeplus`.

### Modern UI matrix

| Floating menu | iOS spoof | Expected | Status |
|---|---|---|---|
| on | off | Floating menu, customizable dock, Subscriptions present and opens the feed | needs device |
| on | on | YouTube falls back to the classic bar; behavior as before, and the spoof is reported in settings | needs device |
| off (classic) | off | Classic bar, YTPlus customization as before (classic hook + `YTPTabHelper`) | needs device |
| on | off, custom dock | YTPlus tab editor order/visibility applied to the floating bar | needs device |
| on | off, Subscriptions on/off | Tab appears/disappears; survives restart | needs device |

Also check:
- Restart persistence.
- Hide/restore of each tab.
- Switching the compatibility switch.
- That *Modern UI › Hooks* lists at least one floating consumer.

### Other modules

- **Downloads:**
  - Queue a video from the watch page's ⋯ menu.
  - Background the app, then terminate it from the app switcher while it runs. On relaunch the download should be recovered.
  - Check pause, resume, cancel and retry.
  - Wait more than 6 hours so the stream link expires, then confirm the 403 message appears.
  - Check that the merged MP4 plays and that audio-only M4A works.
  - Check the file appears in the Files app.
  - Check notifications.
  - Check that YTPlus's own Download button still works.
- **DeArrow:**
  - Feed titles and thumbnails are replaced for videos with submissions.
  - Videos without submissions are unchanged.
  - The title and thumbnail switches work independently.
- **120Hz:**
  - On a ProMotion iPhone, use Quartz Debug or the developer FPS HUD while scrolling feeds: expect up to 120Hz.
  - Video playback cadence should be unchanged.
  - On a 60Hz device the module reports itself inactive.
- **Creator suppression:**
  - "Don't recommend channel" N−1 times: the creator is not hidden.
  - The Nth time: the creator is hidden on Home and Shorts.
  - It still appears in search and on the channel page.
  - Restore works.
  - The manual "Suppress creator" action works.
- **Advanced search:**
  - Long-press the search button.
  - Combine duration range, minimum likes and recency.
  - Remove one filter.
  - Clear all.
  - Switch the sort and confirm the filters are kept.
  - Import a Takeout `comments.csv` and search it.

### Interaction checks

- All six modules enabled together, with and without the MaxTube extras.
- Gonerino and MaxTubePlus suppression together: both filter independently.
- YTPlus's tab editor and the MaxTubePlus floating-menu layer together.
