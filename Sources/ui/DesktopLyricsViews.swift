//
//  DesktopLyricsViews.swift
//  MioIsland Music Plugin
//
//  The three floating lyrics window variants. Shared traits:
//    - NSVisualEffectView-backed blur via .background(.ultraThinMaterial)
//      when available, fallback to semi-transparent color.
//    - Draggable via the window's isMovableByWindowBackground (no extra
//      gesture recognisers needed).
//    - All text / progress / controls bound to NowPlayingState.shared.
//    - Lyric lines are PLACEHOLDER text until we wire a real lyrics
//      source. Only the `lyricLine(_:)` computed below changes when
//      lyrics data becomes available.
//

import AppKit
import SwiftUI

// MARK: - Shared lyric slot helpers

private enum LyricSlot {
    case previous
    case current
    case next
}

/// Pick the right synced-lyric line for a given slot. Falls back to a
/// sensible text when no lyrics are loaded so the window stays readable:
///   - previous / next → "······" (tastefully blank)
///   - current         → track title on cold start, or
///                       L10n.lyricsPlaceholder when paused / not-found
@MainActor
private func lyricText(_ slot: LyricSlot, state: NowPlayingState) -> String {
    let lines = state.syncedLyrics
    let idx = state.currentLyricIndex

    if !lines.isEmpty {
        switch slot {
        case .previous:
            let i = idx - 1
            return (i >= 0 && i < lines.count) ? lines[i].text : "······"
        case .current:
            if idx >= 0 && idx < lines.count { return lines[idx].text }
            // Before first lyric line (elapsedTime < first timestamp).
            return lines.first?.text ?? (state.title.isEmpty ? L10n.lyricsPlaceholder : state.title)
        case .next:
            let i = idx + 1
            return (i >= 0 && i < lines.count) ? lines[i].text : "······"
        }
    }

    // No lyrics loaded / not found — graceful fallback.
    switch slot {
    case .previous: return "······"
    case .current:
        return state.isPlaying
            ? (state.title.isEmpty ? L10n.unknownTitle : state.title)
            : L10n.lyricsPlaceholder
    case .next:
        return state.artist.isEmpty ? "······" : "— \(state.artist)"
    }
}

// MARK: - Shared SVG-equivalent transport controls

private struct MiniControls: View {
    @ObservedObject var state: NowPlayingState = .shared
    let playButtonSize: CGFloat
    let iconButtonSize: CGFloat
    let filledPlay: Bool   // Bar/Karaoke use filled white; Cinema similar

    var body: some View {
        HStack(spacing: 4) {
            button(icon: "backward.fill", size: iconButtonSize) {
                state.previousTrack()
            }
            Button(action: { state.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(filledPlay ? Color.white.opacity(0.95) : Color.white.opacity(0.9))
                        .frame(width: playButtonSize, height: playButtonSize)
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: playButtonSize * 0.42, weight: .bold))
                        .foregroundColor(.black)
                        .offset(x: state.isPlaying ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            button(icon: "forward.fill", size: iconButtonSize) {
                state.nextTrack()
            }
        }
    }

    @ViewBuilder
    private func button(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.001)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private let floatBackground = Color(red: 0x12/255, green: 0x10/255, blue: 0x16/255).opacity(0.62)
private let floatStroke = Color.white.opacity(0.12)

/// ViewModifier applying the shared glass chrome (blur + border + shadow).
private struct FloatChrome: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(floatBackground)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(floatStroke, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 8)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
    }
}

// MARK: - Rotating vinyl disc (for Bar + Cinema)

private struct VinylDisc: View {
    let artwork: NSImage?
    let isPlaying: Bool
    let diameter: CGFloat

    /// TimelineView drives rotation off the monotonic wall clock, which is
    /// immune to SwiftUI re-creating the view (window hide/show, style
    /// switch). `withAnimation(.repeatForever)` used to lose the animation
    /// on re-creation and snap to rest. Wall-clock-based rotation just
    /// always looks right — derive angle from `elapsed % 8s * 45°/s`.
    @State private var pauseAccumulator: Double = 0
    @State private var pauseStart: Date? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { ctx in
            let elapsed = ctx.date.timeIntervalSinceReferenceDate
            // 8-second period → 45°/s. Multiplying by 45 and wrapping to
            // [0, 360) keeps the rotation smooth across many hours without
            // floating-point drift.
            let angle = (elapsed * 45.0).truncatingRemainder(dividingBy: 360)
            disc.rotationEffect(.degrees(angle))
        }
    }

    private var disc: some View {
        ZStack {
            Circle().fill(Color.black)
            if let art = artwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter * 0.55, height: diameter * 0.55)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.9, green: 0.72, blue: 0.53),
                                 Color(red: 0.27, green: 0.35, blue: 0.33)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: diameter * 0.55, height: diameter * 0.55)
            }
            Circle()
                .fill(Color.black)
                .frame(width: diameter * 0.1, height: diameter * 0.1)
        }
        .frame(width: diameter, height: diameter)
        .overlay(
            Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Model 1 · Bar

struct LyricsBarView: View {
    @ObservedObject var state: NowPlayingState = .shared

    var body: some View {
        HStack(spacing: 16) {
            VinylDisc(artwork: state.albumArt, isPlaying: state.isPlaying, diameter: 36)

            Text(lyricText(.current, state: state))
                .font(.system(size: 20, weight: .medium))
                .tracking(-0.1)
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            MiniControls(state: state, playButtonSize: 28, iconButtonSize: 24, filledPlay: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .modifier(FloatChrome(radius: 999))
        .padding(4) // breathing room so shadow isn't clipped by window
    }
}

// MARK: - Model 2 · Karaoke

struct LyricsKaraokeView: View {
    @ObservedObject var state: NowPlayingState = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(red: 0.9, green: 0.72, blue: 0.53))
                    .frame(width: 5, height: 5)
                Text(state.sourceName.isEmpty
                     ? (L10n.isChinese ? "歌词同步" : "Lyrics Sync")
                     : "\(L10n.isChinese ? "歌词同步 · " : "Lyrics · ")\(state.sourceName)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
                Text("\(state.formattedElapsed) / \(state.formattedDuration)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Text("⋮⋮ drag")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.bottom, 12)

            // Current (big)
            Text(lyricText(.current, state: state))
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)

            // Next (faint)
            Text(lyricText(.next, state: state))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .padding(.top, 6)

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 14)

            // Meta + controls row
            HStack(alignment: .center, spacing: 10) {
                albumArtSmall
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title.isEmpty ? L10n.unknownTitle : state.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(state.artist.isEmpty ? L10n.unknownArtist : state.artist)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                MiniControls(state: state, playButtonSize: 32, iconButtonSize: 28, filledPlay: true)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 26, bottom: 18, trailing: 26))
        .modifier(FloatChrome(radius: 20))
        .padding(4)
    }

    @ViewBuilder
    private var albumArtSmall: some View {
        if let art = state.albumArt {
            Image(nsImage: art)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.9, green: 0.72, blue: 0.53),
                             Color(red: 0.27, green: 0.35, blue: 0.33)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 28, height: 28)
        }
    }
}

// MARK: - Model 3 · Cinema

struct LyricsCinemaView: View {
    @ObservedObject var state: NowPlayingState = .shared

    var body: some View {
        VStack(spacing: 0) {
            // Prev line (faint)
            Text(lyricText(.previous, state: state))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
                .lineLimit(1)
                .padding(.bottom, 12)

            // Now line (huge)
            Text(lyricText(.current, state: state))
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 3)

            // Next line (faint)
            Text(lyricText(.next, state: state))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
                .padding(.top, 12)

            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.top, 28)
                .padding(.bottom, 18)

            // Footer
            HStack(spacing: 10) {
                VinylDisc(artwork: state.albumArt, isPlaying: state.isPlaying, diameter: 22)

                Text("\(state.title.isEmpty ? L10n.unknownTitle : state.title) · \(state.artist.isEmpty ? L10n.unknownArtist : state.artist)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)

                Spacer()

                MiniControls(state: state, playButtonSize: 30, iconButtonSize: 30, filledPlay: true)
            }
        }
        .padding(EdgeInsets(top: 40, leading: 40, bottom: 28, trailing: 40))
        .background(
            // Faint color wash for cinema feel
            LinearGradient(
                colors: [
                    Color(red: 0.9, green: 0.72, blue: 0.53).opacity(0.10),
                    Color.clear
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .modifier(FloatChrome(radius: 24))
        .padding(4)
    }
}
