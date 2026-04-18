//
//  ExpandedView.swift
//  MusicPlugin
//
//  Main panel view, sized roughly 620x780 by the host. Four states
//  rendered in priority order:
//    1. Host version too old       (hostVersionOK == false)
//    2. Chinese desktop app running (chineseAppDetected != nil)
//    3. Nothing playing             (title.isEmpty)
//    4. Now playing                 (default)
//
//  Background uses an extracted tint from the album art (fades to
//  near-black). Control surface, text and spacing follow the
//  MioIsland aesthetic:
//    - #0A0A0A near-black base
//    - white text with opacity tiers (1.0 / 0.7 / 0.5 / 0.3)
//    - lime #CAFF00 as the single accent color
//    - 16pt corner on the big card, 8pt on small chips
//

import AppKit
import SwiftUI

struct ExpandedView: View {
    @ObservedObject private var state = NowPlayingState.shared

    /// Tint extracted from the current album art. Updated via
    /// AlbumArtColorExtractor whenever the art changes.
    @State private var tintColor: NSColor?

    private static let lime = Color(
        red: 0xCA / 255.0,
        green: 0xFF / 255.0,
        blue: 0x00 / 255.0
    )
    private static let ink = Color.white
    private static let base = Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0)

    // MARK: - Body

    var body: some View {
        ZStack {
            AlbumArtColorExtractor
                .backgroundGradient(for: tintColor)
                .ignoresSafeArea()

            content
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.base)
        .onAppear { refreshTint(for: state.albumArt) }
        .onChange(of: state.albumArt?.tiffRepresentation) { _, _ in
            refreshTint(for: state.albumArt)
        }
        .animation(.easeInOut(duration: 0.25), value: currentMode)
    }

    // MARK: - State routing

    private enum Mode: Equatable {
        case hostTooOld
        case chineseAppWarning(String)
        case empty
        case playing
    }

    private var currentMode: Mode {
        if !state.hostVersionOK { return .hostTooOld }
        if let name = state.chineseAppDetected, !name.isEmpty {
            return .chineseAppWarning(name)
        }
        if state.title.isEmpty { return .empty }
        return .playing
    }

    @ViewBuilder
    private var content: some View {
        switch currentMode {
        case .hostTooOld:
            warningCard(
                symbol: "exclamationmark.triangle.fill",
                title: L10n.hostUpgradeTitle,
                hint: L10n.hostUpgradeHint,
                tint: .orange
            )
        case .chineseAppWarning(let appName):
            warningCard(
                symbol: "exclamationmark.circle.fill",
                title: L10n.chineseAppTitle(appName),
                hint: L10n.chineseAppHint,
                tint: .yellow
            )
        case .empty:
            emptyCard
        case .playing:
            playingCard
        }
    }

    // MARK: - Playing card

    private var playingCard: some View {
        VStack(spacing: 0) {
            // Header row: small eyebrow + source badge.
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.nowPlayingHeading.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundColor(Self.ink.opacity(0.5))
                Spacer()
                sourceBadge
            }
            .padding(.bottom, 22)

            // Album art (big, centered)
            albumArt
                .padding(.bottom, 24)

            // Title + artist + album
            VStack(spacing: 8) {
                Text(state.title.isEmpty ? L10n.unknownTitle : state.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Self.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(state.artist.isEmpty ? L10n.unknownArtist : state.artist)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Self.ink.opacity(0.75))
                    .lineLimit(1)

                if !state.album.isEmpty {
                    Text(state.album)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Self.ink.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 28)

            // Seek bar + time labels
            VStack(spacing: 6) {
                SeekBar(
                    progress: state.progress,
                    duration: state.duration
                ) { newTime in
                    state.seek(to: newTime)
                }

                HStack {
                    Text(state.formattedElapsed)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Self.ink.opacity(0.5))
                    Spacer()
                    Text(state.formattedDuration)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(Self.ink.opacity(0.5))
                }
            }
            .padding(.bottom, 24)

            // Transport controls
            transportControls
        }
        .frame(maxWidth: 520)
    }

    private var albumArt: some View {
        ZStack {
            if let art = state.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 260, height: 260)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 64, weight: .light))
                            .foregroundColor(Self.ink.opacity(0.35))
                    )
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
    }

    private var sourceBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isPlaying ? Self.lime : Self.ink.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(displaySourceName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Self.ink.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
    }

    private var displaySourceName: String {
        state.sourceName.isEmpty ? "..." : state.sourceName
    }

    private var transportControls: some View {
        HStack(spacing: 40) {
            transportButton(
                symbol: "backward.fill",
                size: 20,
                tooltip: L10n.previousTooltip
            ) {
                state.previousTrack()
            }

            // Play / pause. Larger, accent button.
            Button(action: { state.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(Self.lime)
                        .frame(width: 56, height: 56)
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.black)
                        .offset(x: state.isPlaying ? 0 : 2)  // optical nudge for play
                }
            }
            .buttonStyle(.plain)
            .help(state.isPlaying ? L10n.pauseTooltip : L10n.playTooltip)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.isPlaying)

            transportButton(
                symbol: "forward.fill",
                size: 20,
                tooltip: L10n.nextTooltip
            ) {
                state.nextTrack()
            }
        }
    }

    private func transportButton(
        symbol: String,
        size: CGFloat,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        TransportIconButton(
            symbol: symbol,
            size: size,
            tooltip: tooltip,
            action: action
        )
    }

    // MARK: - Empty card (nothing playing)

    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Self.ink.opacity(0.3))

            Text(L10n.nothingPlaying)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Self.ink.opacity(0.7))

            Text(L10n.nothingPlayingHint)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Self.ink.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: 360)
    }

    // MARK: - Warning cards (host outdated / chinese app detected)

    private func warningCard(
        symbol: String,
        title: String,
        hint: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(tint)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Self.ink.opacity(0.9))
                .multilineTextAlignment(.center)

            Text(hint)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Self.ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(28)
        .frame(maxWidth: 380)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Tint refresh

    private func refreshTint(for image: NSImage?) {
        // Prefer the tint NowPlayingState already computed (if data source
        // pushed one), but fall back to extracting here. Either way, we
        // re-run extraction so the gradient tracks the current art.
        if let stateColor = state.albumArtColor {
            tintColor = stateColor
            return
        }
        AlbumArtColorExtractor.extract(from: image) { color in
            tintColor = color
        }
    }
}

// MARK: - Transport icon button

/// Ghost-style round icon button with a lime hover glow. Factored out
/// so it can own its own @State for hover without mutating parent.
private struct TransportIconButton: View {
    let symbol: String
    let size: CGFloat
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false

    private static let lime = Color(
        red: 0xCA / 255.0,
        green: 0xFF / 255.0,
        blue: 0x00 / 255.0
    )

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(isHovered ? Self.lime : Color.white.opacity(0.75))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.10 : 0.0))
                )
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
