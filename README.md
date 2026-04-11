# Music Player Plugin for MioIsland

A native plugin that brings real-time music playback information to your MioIsland Notch bar. See what's currently playing across any music app on your Mac without leaving your workflow.

## Features

- Displays the currently playing track, artist, and album from any macOS music app (Apple Music, Spotify, etc.)
- Reads system NowPlaying metadata — no need to configure individual apps
- Lightweight native `.bundle` plugin with minimal resource usage
- Smooth animated UI that matches the MioIsland design language
- Appears as a header icon button in the Notch bar

## Screenshots

*Coming soon*

## Installation

### From MioIsland Plugin Store

1. Visit [miomio.chat](https://miomio.chat)
2. Find "Music Player" and click Install
3. MioIsland will automatically download and activate the plugin

### Manual Installation

```bash
cp -r music-player.bundle ~/.config/codeisland/plugins/
```

Restart MioIsland to load the plugin.

## Building from Source

Requirements:
- macOS 15.0+
- Xcode Command Line Tools
- Swift 5.9+

```bash
git clone https://github.com/xmqywx/mio-plugin-music.git
cd mio-plugin-music
bash build.sh
```

The build script outputs:
- `build/music-player.bundle` — the plugin (copy to `~/.config/codeisland/plugins/`)
- `build/music-player.zip` — compressed bundle for marketplace upload

## Plugin Architecture

| File | Purpose |
|------|---------|
| `MioPlugin.swift` | Plugin protocol definition |
| `MusicPlugin.swift` | Main plugin entry point — activate, deactivate, makeView |
| `MusicPlayerView.swift` | SwiftUI view displaying track info |
| `MusicHeaderButton.swift` | Header icon button for the Notch bar |
| `NowPlayingBridge.swift` | Bridges macOS NowPlaying system APIs |

## How It Works

The plugin uses macOS `MRMediaRemoteGetNowPlayingInfo` API to read the system-wide NowPlaying information. This works with any app that reports playback status to the system, including:

- Apple Music
- Spotify
- YouTube (in browser)
- VLC
- Any app using MPNowPlayingInfoCenter

## License

MIT

## Author

[@xmqywx](https://github.com/xmqywx)
