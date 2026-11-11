## %release_prefix% release info
- **YT version:** `%yt_version%` (MaxTubePlus target: 21.42.4)
- **YTPlus:** `%ytlite_version%`
- **iOS 15+** (120Hz requires a ProMotion device)

### MaxTubePlus modules
- **Background downloads:** a background transfer queue with pause, resume, cancel and retry, recovery after the app closes, notifications and storage management. YTPlus's downloader is unchanged.
- **DeArrow:** community titles and thumbnails from [dearrow.ajay.app](https://dearrow.ajay.app). Data is CC BY-NC-SA 4.0.
- **120Hz interface** on ProMotion devices. Video frame rates are left untouched.
- **Creator suppression:** learns from repeated "Don't recommend channel".
- **Advanced search:** duration range, minimum likes, upload date and recency filters, sorting, and search of commented videos imported from Takeout.
- **Floating menu compatibility:** YTPlus dock customization and the Subscriptions tab work with YouTube's newer floating menu, without spoofing iOS 17.

Settings live in YouTube › Settings › MaxTubePlus, which also shows live compatibility status.
Not every module has been verified on a device for every YouTube build. See [docs/TESTING.md](https://github.com/trail-b1az3r/Maxtubeplus-/blob/main/docs/TESTING.md).
