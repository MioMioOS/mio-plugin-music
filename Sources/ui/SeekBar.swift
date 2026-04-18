//
//  SeekBar.swift
//  MusicPlugin
//
//  Draggable progress bar used at the bottom of the expanded card.
//  Visual rules:
//    - 4pt tall normally, grows to 6pt on hover.
//    - Background track white @ 10%.
//    - Filled portion lime #CAFF00.
//    - 12x12 white knob shows only on hover or during drag.
//    - Dragging updates a local preview; onEnded commits via seek(to:).
//

import SwiftUI

struct SeekBar: View {
    /// Current progress in 0...1 driven by NowPlayingState.
    let progress: Double
    /// Track total duration (seconds), needed to compute the final
    /// seek target when the drag ends.
    let duration: TimeInterval
    /// Called with an absolute time (seconds) when the user finishes
    /// dragging. Not called mid-drag.
    let onSeek: (TimeInterval) -> Void

    // Lime brand accent.
    private static let lime = Color(
        red: 0xCA / 255.0,
        green: 0xFF / 255.0,
        blue: 0x00 / 255.0
    )

    @State private var dragProgress: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let displayed = min(max(dragProgress ?? progress, 0), 1)
            let trackHeight: CGFloat = (isHovering || dragProgress != nil) ? 6 : 4
            let knobSize: CGFloat = 12
            let knobCenterX = CGFloat(displayed) * geometry.size.width
            let knobVisible = isHovering || dragProgress != nil

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: trackHeight)

                // Filled portion
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Self.lime)
                    .frame(
                        width: max(0, geometry.size.width * CGFloat(displayed)),
                        height: trackHeight
                    )
                    .animation(.easeInOut(duration: 0.2), value: displayed)

                // Knob
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: max(0, knobCenterX - knobSize / 2))
                    .opacity(knobVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: knobVisible)
            }
            .frame(height: 16, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        let next = min(max(value.location.x / geometry.size.width, 0), 1)
                        dragProgress = next
                    }
                    .onEnded { value in
                        guard geometry.size.width > 0, duration > 0 else {
                            dragProgress = nil
                            return
                        }
                        let next = min(max(value.location.x / geometry.size.width, 0), 1)
                        dragProgress = nil
                        onSeek(duration * next)
                    }
            )
            .animation(.easeInOut(duration: 0.2), value: trackHeight)
        }
        .frame(height: 16)
    }
}
