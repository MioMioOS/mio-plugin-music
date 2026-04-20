//
//  DesktopLyricsWindow.swift
//  MioIsland Music Plugin
//
//  Floating desktop "lyrics" overlay window — always-on-top, movable by
//  dragging anywhere on its background, dismissable with Escape. Three
//  style variants the user can cycle through:
//
//    • Bar     (Model 1) — narrow single-line pill, 520×64
//    • Karaoke (Model 2) — two-line card, current + next, 560×170
//    • Cinema  (Model 3) — 3-line large typography, 640×260
//
//  All variants derive their title/artist/progress/isPlaying from
//  NowPlayingState.shared. Lyrics data is NOT yet piped in (MediaRemote
//  adapter doesn't expose lyric timings and there's no public API on
//  Apple Music / Spotify), so the "lyric line" slot shows a placeholder
//  string. When a lyric source lands, only the `currentLine` /
//  `nextLine` / `prevLine` computed properties need to change.
//
//  Window is one per app — `DesktopLyricsWindow.shared` serves toggles
//  from the ExpandedView's pin button.
//

import AppKit
import SwiftUI
import Combine

// MARK: - Style enum

enum LyricsStyle: String, CaseIterable, Identifiable {
    case bar
    case karaoke
    case cinema

    var id: String { rawValue }

    var windowSize: CGSize {
        switch self {
        case .bar:     return CGSize(width: 520, height: 64)
        case .karaoke: return CGSize(width: 560, height: 170)
        case .cinema:  return CGSize(width: 640, height: 260)
        }
    }

    var displayName: String {
        switch self {
        case .bar:     return L10n.isChinese ? "单行胶囊" : "Bar"
        case .karaoke: return L10n.isChinese ? "双行卡拉" : "Karaoke"
        case .cinema:  return L10n.isChinese ? "影院大字" : "Cinema"
        }
    }
}

// MARK: - Window

@MainActor
final class DesktopLyricsWindow {
    static let shared = DesktopLyricsWindow()

    private var window: NSWindow?
    private let stylePrefsKey = "mio.music.lyricsStyle.v1"

    private init() {}

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if let existing = window {
            existing.orderFront(nil)
            return
        }

        let style = loadStyle()
        let root = DesktopLyricsRootView(initialStyle: style) { [weak self] newStyle in
            self?.saveStyle(newStyle)
            self?.resizeTo(newStyle.windowSize)
        }
        let host = NSHostingView(rootView: root)

        let win = DraggableBorderlessWindow(
            contentRect: NSRect(origin: .zero, size: style.windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = host
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.level = .floating           // always-on-top
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false  // we need clicks for controls
        win.isReleasedWhenClosed = false

        // Default placement — bottom center of the primary screen, 80pt
        // above the Dock. User can drag from there.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let x = f.midX - style.windowSize.width / 2
            let y = f.minY + 80
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        win.orderFront(nil)
        window = win
    }

    func hide() {
        window?.orderOut(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func resizeTo(_ size: CGSize) {
        guard let win = window else { return }
        var frame = win.frame
        frame.origin.y += (frame.size.height - size.height) // anchor to bottom edge
        frame.size = size
        win.setFrame(frame, display: true, animate: true)
    }

    private func loadStyle() -> LyricsStyle {
        if let raw = UserDefaults.standard.string(forKey: stylePrefsKey),
           let s = LyricsStyle(rawValue: raw) {
            return s
        }
        return .bar
    }

    private func saveStyle(_ style: LyricsStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: stylePrefsKey)
    }
}

// Borderless NSWindows can become key (so Escape works) and swallow the
// mouse events on our control buttons while still letting drag-background
// move the window.
private final class DraggableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // Escape → hide (consistent with other floating overlays).
        if event.keyCode == 53 {
            DesktopLyricsWindow.shared.hide()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Root view

/// Hosts the style picker + the currently selected variant. State-changing
/// props go up to the window via the `onStyleChange` callback so the
/// window can resize.
private struct DesktopLyricsRootView: View {
    @ObservedObject private var state = NowPlayingState.shared
    @State private var style: LyricsStyle
    let onStyleChange: (LyricsStyle) -> Void

    init(initialStyle: LyricsStyle, onStyleChange: @escaping (LyricsStyle) -> Void) {
        _style = State(initialValue: initialStyle)
        self.onStyleChange = onStyleChange
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch style {
                case .bar:     LyricsBarView()
                case .karaoke: LyricsKaraokeView()
                case .cinema:  LyricsCinemaView()
                }
            }
            .transition(.opacity)

            // Tiny style-cycle chip in the very corner — minimal, only
            // visible on hover to stay out of the way.
            StyleCyclerChip(current: style) { next in
                withAnimation(.easeInOut(duration: 0.2)) {
                    style = next
                }
                onStyleChange(next)
            }
            .padding(8)
        }
        .frame(
            width: style.windowSize.width,
            height: style.windowSize.height
        )
    }
}

// MARK: - Cycle chip

private struct StyleCyclerChip: View {
    let current: LyricsStyle
    let onChange: (LyricsStyle) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            let all = LyricsStyle.allCases
            let idx = all.firstIndex(of: current) ?? 0
            onChange(all[(idx + 1) % all.count])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.3.offgrid")
                    .font(.system(size: 9, weight: .semibold))
                Text(current.displayName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.black.opacity(isHovered ? 0.45 : 0.25))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L10n.lyricsStyleLabel)
    }
}
