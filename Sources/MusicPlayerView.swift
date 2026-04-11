//
//  MusicPlayerView.swift
//  MioIsland Music Plugin
//
//  Compact Now Playing UI designed for the notch panel.
//

import SwiftUI

struct MusicPlayerView: View {
    @ObservedObject var bridge = NowPlayingBridge.shared

    var body: some View {
        if bridge.info.title.isEmpty {
            emptyState
        } else {
            nowPlayingView
        }
    }

    // MARK: - Now Playing

    private var nowPlayingView: some View {
        HStack(spacing: 12) {
            // Album art
            if let artwork = bridge.info.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.3))
                    )
            }

            // Info + controls
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(bridge.info.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)

                // Artist
                Text(bridge.info.artist)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)

                // Progress bar
                if bridge.info.duration > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.white.opacity(0.1))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.white.opacity(0.6))
                                .frame(width: geo.size.width * progress, height: 3)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Playback controls
            HStack(spacing: 14) {
                controlButton("backward.fill") { bridge.previousTrack() }
                controlButton(bridge.info.isPlaying ? "pause.fill" : "play.fill") { bridge.togglePlayPause() }
                    .font(.system(size: 14))
                controlButton("forward.fill") { bridge.nextTrack() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.25))
            Text("Nothing playing")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private var progress: CGFloat {
        guard bridge.info.duration > 0 else { return 0 }
        return CGFloat(bridge.info.elapsedTime / bridge.info.duration)
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }
}
