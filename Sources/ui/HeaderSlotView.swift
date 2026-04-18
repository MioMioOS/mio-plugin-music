//
//  HeaderSlotView.swift
//  MusicPlugin
//
//  Tiny 20x20 icon that lives in the notch header slot. Shows:
//    - A music.note SF symbol tinted by play state.
//    - 3 thin "pseudo-spectrum" bars breathing next to it when playing.
//    - 1.15x hover scale + pointing-hand cursor.
//  Tap posts .openPlugin (userInfo = ["pluginId": "music-player"]) so
//  the host app knows to slide the music plugin view into focus.
//

import AppKit
import SwiftUI

/// Notification the host listens for to switch the notch panel to a
/// specific plugin. Matches the existing openPlugin contract used by
/// other plugins.
extension Notification.Name {
    static let openPlugin = Notification.Name("com.codeisland.openPlugin")
}

struct HeaderSlotView: View {
    @ObservedObject private var state = NowPlayingState.shared
    @State private var isHovered = false

    private static let lime = Color(
        red: 0xCA / 255.0,
        green: 0xFF / 255.0,
        blue: 0x00 / 255.0
    )

    var body: some View {
        Button(action: openPluginPanel) {
            HStack(spacing: 2) {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(iconColor)

                // Pseudo spectrum: 3 tiny bars to the right of the note
                if shouldShowBars {
                    PseudoSpectrumBars(isPlaying: state.isPlaying, tint: iconColor)
                        .frame(width: 7, height: 10)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.2), value: state.isPlaying)
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

    private var shouldShowBars: Bool {
        // Hide bars entirely in "idle" (no track at all), feels cleaner.
        // Show them (static) in paused, (breathing) in playing.
        !state.title.isEmpty
    }

    private var iconColor: Color {
        if state.isPlaying { return Self.lime }
        if !state.title.isEmpty { return Color.white.opacity(0.5) }
        return Color.white.opacity(0.25)
    }

    private func openPluginPanel() {
        NotificationCenter.default.post(
            name: .openPlugin,
            object: nil,
            userInfo: ["pluginId": "music-player"]
        )
    }
}

// MARK: - Pseudo spectrum (3 bars)

/// 3 tiny vertical bars that "breathe" when music is playing. Heights
/// are driven by sin() against a TimelineView clock so we animate
/// smoothly without an NSTimer.
private struct PseudoSpectrumBars: View {
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(tint)
                        .frame(width: 1.5, height: barHeight(index: i, time: time))
                }
            }
        }
    }

    /// Height in 2...8pt. Each bar gets a distinct phase so they
    /// don't rise in sync. When paused we hold a quiet mid-height.
    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return 4 }
        // Each bar has its own frequency + phase offset so they feel
        // independent. Frequencies chosen by ear to look "alive" but
        // not frantic at 0.15s updates.
        let freq = [2.1, 3.3, 2.7][index]
        let phase = [0.0, 1.1, 2.4][index]
        let raw = sin(time * freq + phase)        // -1...1
        let normalized = (raw + 1) * 0.5           // 0...1
        return 2 + CGFloat(normalized) * 6         // 2...8
    }
}
