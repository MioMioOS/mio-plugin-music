//
//  MusicHeaderButton.swift
//  MioIsland Music Plugin
//
//  Small button for the "header" slot — shows a music note icon
//  that posts a notification to open the music plugin view.
//

import AppKit
import SwiftUI

/// Notification name that the host app listens for to navigate to a plugin.
/// The userInfo dict contains ["pluginId": String].
extension Notification.Name {
    static let openPlugin = Notification.Name("com.codeisland.openPlugin")
}

struct MusicHeaderButtonView: View {
    @ObservedObject var bridge = NowPlayingBridge.shared
    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .openPlugin,
                object: nil,
                userInfo: ["pluginId": "music-player"]
            )
        } label: {
            Image(systemName: "music.note")
                .font(.system(size: 10))
                .foregroundColor(
                    isHovered
                        ? Color(red: 1.0, green: 0.4, blue: 0.6)  // 荧光粉色
                        : (bridge.info.isPlaying ? .white.opacity(0.8) : .white.opacity(0.4))
                )
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .frame(width: 20, height: 20)
        .fixedSize()
    }
}
