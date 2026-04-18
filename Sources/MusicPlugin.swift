//
//  MusicPlugin.swift
//  MioIsland Music Plugin
//
//  Principal class for the music-player.bundle plugin (v2.0.0).
//
//  Wires together the data layer (NowPlayingState + sources/*) and the UI
//  layer (ui/*). Loaded at runtime by the host's NativePluginManager via
//  Info.plist -> NSPrincipalClass = "MusicPlugin.MusicPlugin".
//
//  v2.0.0 is a complete rewrite of the v1.0.0 shell. The old files
//  (NowPlayingBridge / MusicPlayerView / MusicHeaderButton) have been
//  replaced by a layered design:
//
//    NowPlayingState  -> orchestrator + sticky source routing
//      +-> sources/MediaRemoteSource     (dlopen private framework)
//      +-> sources/SpotifyAppleScript
//      +-> sources/AppleMusicAppleScript
//      +-> sources/ChromeWebSource       (JS injection into video/audio)
//      +-> support/ChineseAppDetector    (QQ / NetEase / Kugou)
//      +-> support/HostVersionCheck      (host >= 2.1.7 gate)
//
//    ui/ExpandedView     -> main panel (makeView)
//    ui/HeaderSlotView   -> 20x20 header icon + pseudo-spectrum
//    ui/AlbumArtColorExtractor + ui/SeekBar
//    support/Localization (zh/en)
//

import AppKit
import SwiftUI

/// Principal class. Module is `MusicPlugin`, class is `MusicPlugin`, so
/// Info.plist NSPrincipalClass = "MusicPlugin.MusicPlugin".
final class MusicPlugin: NSObject, MioPlugin {
    var id: String { "music-player" }
    var name: String { "Music Player" }
    var icon: String { "music.note" }
    var version: String { "2.0.0" }

    func activate() {
        NSLog("[mio-plugin-music] activate")
        Task { @MainActor in
            NowPlayingState.shared.start()
        }
    }

    func deactivate() {
        NSLog("[mio-plugin-music] deactivate")
        Task { @MainActor in
            NowPlayingState.shared.stop()
        }
    }

    func makeView() -> NSView {
        let view = NSHostingView(rootView: ExpandedView())
        view.autoresizingMask = [.width, .height]
        return view
    }

    @objc func viewForSlot(_ slot: String, context: [String: Any]) -> NSView? {
        switch slot {
        case "header":
            let view = NSHostingView(rootView: HeaderSlotView())
            view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            view.setFrameSize(NSSize(width: 20, height: 20))
            return view
        default:
            return nil
        }
    }
}
