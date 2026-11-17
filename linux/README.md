# MaxTubePlus Desktop (Arch Linux)

A native GTK4/libadwaita YouTube client that brings MaxTubePlus's features to
Linux. It shares MaxTubePlus's C core (`MaxTubePlus/Core/MTPCore.c`): the same
filter, ban, fuzzy-matching and search-parameter code as the iOS tweak, compiled
to `libmtpcore.so`.

An iOS app (the IPA) cannot run on Linux: it is an arm64 iOS binary built on
UIKit and Apple frameworks. So this is a new desktop app that reuses
MaxTubePlus's own code. It does not convert, contain or copy YouTube's iOS app
or its branding.

## Install

```sh
git clone https://github.com/trail-b1az3r/Maxtubeplus-.git
cd Maxtubeplus-/linux
makepkg -si
```

Then launch **MaxTubePlus** from your app menu, or run `maxtubeplus`. CI also
builds a ready-made `.pkg.tar.zst` (Actions › "Arch Linux package") that you can
install with `sudo pacman -U maxtubeplus-desktop-*.pkg.tar.zst`.

## Features

| Feature | Desktop behaviour |
|---|---|
| Advanced search | Filters for duration range, minimum likes (Return YouTube Dislike), upload date, recency, topics and `#tags` (include or exclude), flexible dates, loose names, and relevance or recency sort. Filters are sent to YouTube's own search, and the exact bounds are then applied to each result. |
| Banned creators | Add an `@handle` and everything from that creator is hidden in Search and Subscriptions. The handle is resolved to a channel ID and name. |
| DeArrow | Community titles and thumbnails, cached on disk. When a video has no submission, the original is kept. WebP thumbnails need `webp-pixbuf-loader`. |
| Background downloads | Downloads run through yt-dlp. You can pause, resume, cancel, retry with back-off, and pick quality or audio-only. They keep going when the window is closed, unfinished ones resume on the next start, and you get desktop notifications and a storage view. |
| Commented videos | Import your comments from Google Takeout (`comments.csv`) and search them on your computer. |
| Subscriptions | A local list of channels from their public feeds. No Google account is needed. |
| Playback | Videos open in `mpv`, which streams through yt-dlp. You can change the player in Preferences. |

The following don't apply on desktop:
- The 120Hz patch (mpv handles display sync itself).
- The floating-dock fix.
- Learned "don't recommend" suppression. That needs YouTube's signed-in Home feed; banned creators cover the same need explicitly.

## Data

Everything stays on your computer:
- **Settings, bans, subscriptions, comments:** `~/.config/maxtubeplus`
- **Caches:** `~/.cache/maxtubeplus`
- **Download queue:** `~/.local/share/maxtubeplus`
- **Downloaded files:** `~/Videos/MaxTubePlus`

## Develop

```sh
make core                                  # build libmtpcore.so from ../MaxTubePlus/Core
make test                                  # unit tests (offline)
python -m maxtubeplus_desktop              # run from the source tree
xvfb-run -a python -m maxtubeplus_desktop --self-test   # headless UI check
```

Requirements: GTK ≥ 4.14, libadwaita ≥ 1.5, PyGObject, yt-dlp, deno, mpv, ffmpeg.
