# Music Player Plugin for MioIsland

> **v2.0.0 — full rewrite.** Real Now Playing info from Spotify, Apple Music,
> Google Chrome (YouTube / SoundCloud / 网页版音乐), with playback controls,
> draggable seek bar, album art color tint, and a pseudo-spectrum in the header
> icon. Replaces the v1.0.0 shell that only wired up MediaRemote.

## Features

- **Multi-source playback tracking** with sticky source priority:
  - MediaRemote (private framework, any app that registers with `MPNowPlayingInfoCenter`)
  - Spotify desktop (AppleScript)
  - Apple Music desktop (AppleScript)
  - Google Chrome tabs (JavaScript injection into `<video>` / `<audio>` elements)
- **Full playback controls** — previous, play/pause, next, draggable seek bar
- **Album art color tint** — extracts dominant color from artwork, uses it as a
  soft gradient background in the expanded view
- **Pseudo-spectrum in the Notch** — three animated vertical bars in the header
  icon that pulse while music is playing
- **Bi-lingual** — follows MioIsland's `appLanguage` preference (zh / en)
- **Graceful degradation:**
  - Host too old (< v2.1.7) → shows upgrade banner instead of silently failing
  - Chinese music app running (QQ 音乐 / 网易云 / 酷狗) → shows "desktop not
    supported, try the web version" hint

## Supported music apps

| App | Supported? | How |
|-----|------------|-----|
| **Spotify** desktop | ✅ Full | AppleScript + MediaRemote |
| **Apple Music** desktop | ✅ Full | AppleScript + MediaRemote |
| **YouTube / YouTube Music** in Chrome | ✅ Full | JS injection |
| **SoundCloud** in Chrome | ✅ Full | JS injection |
| **Spotify Web Player** in Chrome | ✅ Full | JS injection |
| **网易云音乐 / QQ 音乐 / 酷狗 (网页版)** in Chrome | ✅ Full | JS injection |
| **网易云音乐 / QQ 音乐** 新版桌面 app | 🟡 Partial | MediaRemote if the app registers (macOS < 15.4 ok; 15.4+ may silently drop) |
| **酷狗桌面 app / 酷我 / 咪咕 / 其他国产** | ❌ Not supported | No MediaRemote, no AppleScript API |
| Any app using `MPNowPlayingInfoCenter` | ✅ | MediaRemote |

> **macOS 15.4+ note:** Apple restricted `MRMediaRemoteGetNowPlayingInfo` to
> apps with special entitlements. The plugin auto-falls back to AppleScript
> for Spotify / Apple Music, and to JS injection for Chrome-based sources.

## Installation

### Prerequisite: MioIsland host v2.1.7 or newer

This plugin uses AppleScript to talk to Spotify / Apple Music / Chrome.
macOS requires the host app's `Info.plist` to declare `NSAppleEventsUsageDescription`
for that. MioIsland added this key in **v2.1.7** — older hosts will show an
upgrade banner inside the plugin and skip AppleScript sources.

Upgrade the host:
```bash
brew upgrade codeisland
```

Or via MioIsland's in-app update (Sparkle will prompt automatically).

### From MioIsland Plugin Store (recommended)

1. Open **MioIsland Settings → Plugins**
2. Click **打开插件市场 (Open Plugin Store)** — opens https://miomio.chat
3. Find **Music Player v2.0.0** and click **Install**
4. Copy the generated `https://api.miomio.chat/api/i/...` URL
5. Paste into the **Install from URL** field and click **Install**
6. Restart MioIsland (menu bar → quit → relaunch)

### Manual installation

```bash
# Download the latest release from GitHub
curl -LO https://github.com/MioMioOS/mio-plugin-music/releases/latest/download/music-player.zip
unzip music-player.zip
mkdir -p ~/.config/codeisland/plugins/
cp -R music-player.bundle ~/.config/codeisland/plugins/
# Restart MioIsland
```

### First-run permissions

When the plugin fetches track info for the first time, macOS will prompt:

> "Mio Island" would like to control "Spotify".app.

Click **OK**. Do the same for **Music.app** and **Google Chrome** when they
come up. These permissions are granted to the host app once and remembered
forever — subsequent launches don't re-prompt.

If you accidentally clicked **Don't Allow**, fix it in:
**System Settings → Privacy & Security → Automation** → toggle Mio Island on
for each target app.

### Chrome-specific setup

To get Chrome playback (YouTube, SoundCloud, etc.) working:

1. Open Chrome
2. Menu bar: **View → Developer → Allow JavaScript from Apple Events**
3. Check the option (click if unchecked)

This is a one-time setting that lives in Chrome's preferences. Without it,
AppleScript JS injection will silently return nothing for Chrome tabs.

## Building from source

Requirements:
- macOS 15.0+
- Xcode 16+ Command Line Tools
- Swift 5.10+

```bash
git clone https://github.com/MioMioOS/mio-plugin-music.git
cd mio-plugin-music
./build.sh              # → build/music-player.bundle + build/music-player.zip
./build.sh install      # (not implemented — copy manually)
```

Install the build output:
```bash
cp -R build/music-player.bundle ~/.config/codeisland/plugins/
```

Restart MioIsland.

## Plugin architecture (v2.0.0)

```
Sources/
├── MioPlugin.swift              — plugin SDK protocol (DO NOT MODIFY)
├── MusicPlugin.swift            — principal class (activate / makeView / header slot)
├── NowPlayingState.swift        — @MainActor ObservableObject, source router
├── sources/
│   ├── MediaRemoteSource.swift  — dlopen private MediaRemote.framework
│   ├── SpotifyAppleScript.swift
│   ├── AppleMusicAppleScript.swift
│   └── ChromeWebSource.swift    — JS injection into <video> / <audio>
├── ui/
│   ├── ExpandedView.swift       — main 620×780 panel
│   ├── HeaderSlotView.swift     — 20×20 header icon + pseudo-spectrum
│   ├── AlbumArtColorExtractor.swift
│   └── SeekBar.swift
└── support/
    ├── ChineseAppDetector.swift — QQ / NetEase / Kugou detection
    ├── HostVersionCheck.swift   — host ≥ v2.1.7 gate
    └── Localization.swift       — zh / en strings
```

**Source priority routing:** sticky (last successful) → MediaRemote → Spotify →
Apple Music → Chrome. First source that returns non-empty playback state wins.
3-second poll timer drives periodic refresh; Spotify and Music distributed
notifications trigger immediate refresh for instant reaction.

## Privacy

The plugin reads only:
- System-level Now Playing metadata (MediaRemote)
- Current track info from Spotify / Music / Chrome via AppleScript
- Bundle IDs of running apps to detect which source is active

It does **not** read:
- Your listening history
- Anything outside the "currently playing" state
- Anything from apps that are not music-related

Nothing is sent to any server. All processing happens locally.

## License

MIT. See LICENSE.

## Author

[@xmqywx](https://github.com/xmqywx) — part of the [MioMioOS](https://github.com/MioMioOS)
official plugin set.
