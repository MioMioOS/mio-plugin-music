//
//  MusicPlugin.swift
//  MioIsland Music Plugin
//
//  Principal class for the music-player.bundle plugin.
//  Shows system Now Playing info (Spotify, Apple Music, etc.)
//  with playback controls in the notch.
//

import AppKit
import SwiftUI

final class MusicPlugin: NSObject, MioPlugin {
    var id: String { "music-player" }
    var name: String { "Music Player" }
    var icon: String { "music.note" }
    var version: String { "1.0.0" }

    func activate() {
        Task { @MainActor in
            NowPlayingBridge.shared.start()
        }
    }

    func deactivate() {
        Task { @MainActor in
            NowPlayingBridge.shared.stop()
        }
    }

    func makeView() -> NSView {
        NSHostingView(rootView: MusicPlayerView())
    }

    func viewForSlot(_ slot: String, context: [String: Any]) -> NSView? {
        switch slot {
        case "header":
            let view = NSHostingView(rootView: MusicHeaderButtonView())
            view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            view.setFrameSize(NSSize(width: 20, height: 20))
            return view
        default:
            return nil
        }
    }
}
