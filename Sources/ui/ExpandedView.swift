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
//  v2.0.1 layout: compact horizontal hero inspired by SuperIsland's
//  NowPlaying. Medium album art on the left, metadata + source badge
//  on the right, progress + times inline below, transport controls
//  at bottom. Half the vertical footprint of v2.0.0 for the same
//  information density.
//
//  Background uses a tint extracted from the album art (fades into
//  a near-black base). Palette:
//    #0A0A0A near-black base
//    white text tiers 1.0 / 0.75 / 0.45 / 0.3
//    lime #CAFF00 as the single accent color
//    16pt corner on the big art, 8pt on small chips
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
                .padding(20)
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

    // MARK: - Playing card — compact horizontal layout

    private var playingCard: some View {
        VStack(spacing: 16) {
            // Hero row: album art left, metadata + source badge right
            HStack(alignment: .top, spacing: 14) {
                albumArt

                VStack(alignment: .leading, spacing: 4) {
                    // Source badge, flush right with the artwork top
                    HStack {
                        Spacer()
                        sourceBadge
                    }

                    Text(state.title.isEmpty ? L10n.unknownTitle : state.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Self.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(state.artist.isEmpty ? L10n.unknownArtist : state.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Self.ink.opacity(0.75))
                        .lineLimit(1)

                    if !state.album.isEmpty {
                        Text(state.album)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Self.ink.opacity(0.45))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Progress + times inline on one row
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

            // Transport controls
            transportControls
                .padding(.top, 2)
        }
        .frame(maxWidth: 460)
    }

    private var albumArt: some View {
        ZStack {
            if let art = state.albumArt {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 128, height: 128)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 34, weight: .light))
                            .foregroundColor(Self.ink.opacity(0.35))
                    )
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    private var sourceBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.isPlaying ? Self.lime : Self.ink.opacity(0.4))
                .frame(width: 5, height: 5)
            Text(displaySourceName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Self.ink.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
    }

    private var displaySourceName: String {
        state.sourceName.isEmpty ? "..." : state.sourceName
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            transportButton(
                symbol: "backward.fill",
                size: 16,
                tooltip: L10n.previousTooltip
            ) {
                state.previousTrack()
            }

            // Play / pause — accent button, slightly smaller than v2.0.0 (48 vs 56)
            Button(action: { state.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(Self.lime)
                        .frame(width: 48, height: 48)
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                        .offset(x: state.isPlaying ? 0 : 2)  // optical nudge for play glyph
                }
            }
            .buttonStyle(.plain)
            .help(state.isPlaying ? L10n.pauseTooltip : L10n.playTooltip)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.isPlaying)

            transportButton(
                symbol: "forward.fill",
                size: 16,
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
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Self.ink.opacity(0.3))

            Text(L10n.nothingPlaying)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Self.ink.opacity(0.7))

            Text(L10n.nothingPlayingHint)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Self.ink.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: 320)
    }

    // MARK: - Warning cards (host outdated / chinese app detected)

    private func warningCard(
        symbol: String,
        title: String,
        hint: String,
        tint: Color
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .regular))
                .foregroundColor(tint)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Self.ink.opacity(0.9))
                .multilineTextAlignment(.center)

            Text(hint)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Self.ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(22)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                .frame(width: 36, height: 36)
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
