//
//  NowPlayingState.swift
//  MioIsland Music Plugin
//
//  Single source of truth consumed by the SwiftUI layer. Aggregates four
//  backend sources, in priority order:
//
//    1. The most recently successful source (sticky preference so we do not
//       thrash between Spotify / Music / Chrome on every poll).
//    2. MediaRemote (private framework; falls back on macOS 15.4+ where it
//       returns an empty dictionary without a special entitlement).
//    3. Spotify desktop via AppleScript.
//    4. Apple Music via AppleScript.
//    5. Google Chrome tab via JS injection.
//
//  Also checks:
//    - Host version (must be ≥ 2.1.7 for NSAppleEventsUsageDescription).
//    - Chinese desktop players (QQ 音乐 / 网易云 / 酷狗) so we can show a
//      "desktop unsupported, use web" state instead of empty UI.
//
//  Timing:
//    - 3 second poll timer drives periodic refresh.
//    - MediaRemote notifications (when available) trigger immediate refresh.
//    - A 1 second local timer advances elapsedTime while isPlaying is true.
//

import AppKit
import Combine

// MARK: - Source enum

enum NowPlayingSourceKind: String {
    case none
    case mediaRemote
    case spotify
    case appleMusic
    case chrome
}

// MARK: - State

@MainActor
final class NowPlayingState: ObservableObject {
    static let shared = NowPlayingState()

    // Track info
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var albumArt: NSImage?

    /// Populated by Worker B's AlbumArtColorExtractor once albumArt changes.
    @Published var albumArtColor: NSColor?

    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0

    /// Human readable source label ("Spotify" / "Apple Music" / "YouTube" / …)
    @Published var sourceName: String = ""

    /// Bundle identifier of the app that owns the current playback, for
    /// NSWorkspace icon lookups by the UI layer.
    @Published var sourceBundleId: String = ""

    /// False when Mio Island host is older than HostVersionCheck.minRequired.
    /// UI should show an upgrade banner and skip AppleScript sources.
    @Published var hostVersionOK: Bool = true

    /// Non-nil when a Chinese desktop player is running. UI shows a "桌面端
    /// 暂不支持，请使用网页版" hint.
    @Published var chineseAppDetected: String?

    // MARK: - Derived

    var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, elapsedTime / duration))
    }

    var formattedElapsed: String { Self.format(elapsedTime) }
    var formattedDuration: String { Self.format(duration) }

    private static func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Private

    private let mediaRemote = MediaRemoteSource()
    private var pollTimer: Timer?
    private var playbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var stickySource: NowPlayingSourceKind = .none
    private var lastChromeTabURL: String = ""
    private var isRunning = false
    private var refreshInFlight = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        NSLog("[mio-plugin-music] NowPlayingState.start")

        hostVersionOK = HostVersionCheck.isOK()
        chineseAppDetected = ChineseAppDetector.detectRunning()

        mediaRemote.registerForNotifications { [weak self] in
            Task { @MainActor in self?.refresh() }
        }

        // Observe Spotify distributed notifications for instant reaction.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )

        // Observe Apple Music similarly.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(musicStateChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        startPolling()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        NSLog("[mio-plugin-music] NowPlayingState.stop")

        pollTimer?.invalidate()
        pollTimer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func spotifyStateChanged() {
        Task { @MainActor in self.refresh() }
    }

    @objc private func musicStateChanged() {
        Task { @MainActor in self.refresh() }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Source router

    private func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        // Refresh Chinese app detection each pass; user may launch/quit them.
        chineseAppDetected = ChineseAppDetector.detectRunning()

        let allowAppleScript = hostVersionOK

        Task { [weak self] in
            guard let self else { return }
            await self.routeSources(allowAppleScript: allowAppleScript)
            await MainActor.run { self.refreshInFlight = false }
        }
    }

    private func routeSources(allowAppleScript: Bool) async {
        // Build the order: sticky source first, then the default chain.
        let defaultOrder: [NowPlayingSourceKind] = [
            .mediaRemote, .spotify, .appleMusic, .chrome
        ]
        var order: [NowPlayingSourceKind] = []
        if stickySource != .none { order.append(stickySource) }
        for kind in defaultOrder where kind != stickySource {
            order.append(kind)
        }

        for kind in order {
            // Skip AppleScript sources when the host cannot grant permission.
            if !allowAppleScript, kind != .mediaRemote { continue }

            if let used = await tryFetch(kind) {
                await MainActor.run {
                    self.stickySource = used
                    self.updatePlaybackTimer()
                }
                return
            }
        }

        // Nothing returned a hit; clear state.
        await MainActor.run {
            self.clearTrack()
            self.stickySource = .none
            self.updatePlaybackTimer()
        }
    }

    /// Try a single source. Returns the source kind on success, nil on miss.
    private func tryFetch(_ kind: NowPlayingSourceKind) async -> NowPlayingSourceKind? {
        switch kind {
        case .none:
            return nil

        case .mediaRemote:
            let info: MediaRemoteInfo? = await withCheckedContinuation { cont in
                Task { @MainActor in
                    self.mediaRemote.fetchInfo { cont.resume(returning: $0) }
                }
            }
            guard let info, info.hasTrack else { return nil }
            await MainActor.run { self.apply(mediaRemote: info) }
            return .mediaRemote

        case .spotify:
            guard let info = await SpotifyAppleScript.fetch(), !info.title.isEmpty else { return nil }
            await MainActor.run { self.apply(appleScript: info) }
            if self.albumArt == nil, let art = await SpotifyAppleScript.fetchArtwork() {
                await MainActor.run { self.albumArt = art }
            }
            return .spotify

        case .appleMusic:
            guard let info = await AppleMusicAppleScript.fetch(), !info.title.isEmpty else { return nil }
            await MainActor.run { self.apply(appleScript: info) }
            return .appleMusic

        case .chrome:
            guard let info = await ChromeWebSource.fetch(), !info.title.isEmpty else { return nil }
            await MainActor.run { self.apply(chrome: info) }
            if let artURL = info.artworkURL, let url = URL(string: artURL) {
                if let image = await downloadImage(from: url) {
                    await MainActor.run { self.albumArt = image }
                }
            }
            return .chrome
        }
    }

    // MARK: - Apply

    private func apply(mediaRemote info: MediaRemoteInfo) {
        self.title = info.title
        self.artist = info.artist
        self.album = info.album
        self.duration = info.duration
        self.elapsedTime = info.elapsedTime
        self.isPlaying = info.isPlaying
        self.albumArt = info.artwork
        self.sourceName = "System Media"
        self.sourceBundleId = info.bundleIdentifier
        self.lastChromeTabURL = ""
    }

    private func apply(appleScript info: AppleScriptTrackInfo) {
        self.title = info.title
        self.artist = info.artist
        self.album = info.album
        self.duration = info.duration
        self.elapsedTime = info.elapsedTime
        self.isPlaying = info.isPlaying
        self.sourceName = info.source
        self.sourceBundleId = info.bundleId
        self.lastChromeTabURL = ""
    }

    private func apply(chrome info: ChromeTrackInfo) {
        self.title = info.title
        self.artist = info.artist
        self.album = ""
        self.duration = info.duration
        self.elapsedTime = info.elapsedTime
        self.isPlaying = info.isPlaying
        self.sourceName = info.sourceName
        self.sourceBundleId = ChromeWebSource.bundleId
        self.lastChromeTabURL = info.tabURL
    }

    private func clearTrack() {
        title = ""
        artist = ""
        album = ""
        albumArt = nil
        isPlaying = false
        duration = 0
        elapsedTime = 0
        sourceName = ""
        sourceBundleId = ""
    }

    // MARK: - Playback timer

    private func updatePlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        guard isPlaying, duration > 0 else { return }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.elapsedTime = min(self.elapsedTime + 1.0, self.duration)
                if self.elapsedTime >= self.duration {
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                }
            }
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        // Optimistically flip so the UI feels responsive.
        let shouldPlay = !isPlaying
        isPlaying = shouldPlay
        updatePlaybackTimer()

        switch stickySource {
        case .spotify:
            SpotifyAppleScript.togglePlay()
        case .appleMusic:
            AppleMusicAppleScript.togglePlay()
        case .chrome:
            let url = lastChromeTabURL.isEmpty ? nil : lastChromeTabURL
            Task { _ = await ChromeWebSource.togglePlay(shouldPlay: shouldPlay, preferredURL: url) }
        case .mediaRemote, .none:
            mediaRemote.sendCommand(.togglePlayPause)
        }

        // Confirm from the real source after a short delay.
        scheduleRefresh(after: 0.3)
    }

    func nextTrack() {
        switch stickySource {
        case .spotify:
            SpotifyAppleScript.next()
        case .appleMusic:
            AppleMusicAppleScript.next()
        case .chrome:
            // Chrome has no generic "next" control across sites.
            mediaRemote.sendCommand(.nextTrack)
        case .mediaRemote, .none:
            mediaRemote.sendCommand(.nextTrack)
        }
        scheduleRefresh(after: 0.3)
    }

    func previousTrack() {
        switch stickySource {
        case .spotify:
            SpotifyAppleScript.previous()
        case .appleMusic:
            AppleMusicAppleScript.previous()
        case .chrome:
            mediaRemote.sendCommand(.previousTrack)
        case .mediaRemote, .none:
            mediaRemote.sendCommand(.previousTrack)
        }
        scheduleRefresh(after: 0.3)
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        elapsedTime = clamped
        updatePlaybackTimer()

        switch stickySource {
        case .spotify:
            SpotifyAppleScript.seek(to: clamped)
        case .appleMusic:
            AppleMusicAppleScript.seek(to: clamped)
        case .chrome:
            let url = lastChromeTabURL.isEmpty ? nil : lastChromeTabURL
            Task { _ = await ChromeWebSource.seek(to: clamped, preferredURL: url) }
        case .mediaRemote, .none:
            mediaRemote.setElapsedTime(clamped)
        }

        scheduleRefresh(after: 0.3)
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.refresh()
        }
    }
}

// MARK: - Shared AppleScript + network helpers (module-level)

/// Background queue dedicated to NSAppleScript. NSAppleScript is documented
/// as thread safe only within a single thread, so we keep all invocations
/// serial on this queue and marshal results back via async continuations.
private let appleScriptQueue = DispatchQueue(
    label: "mio-plugin-music.applescript",
    qos: .userInitiated
)

/// Execute an AppleScript source string asynchronously. Returns the string
/// value of the result or nil on error. Error numbers are split into:
///   -600  : application is not running (normal, silent)
///   -1728 : Apple Event descriptor error (often benign, silent)
///   other : logged via NSLog with a tag
func runAppleScript(_ source: String, tag: String) async -> String? {
    await withCheckedContinuation { continuation in
        appleScriptQueue.async {
            var errorDict: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                continuation.resume(returning: nil)
                return
            }
            let result = script.executeAndReturnError(&errorDict)
            if let errorDict {
                let num = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
                if num != -600 && num != -1728 {
                    let msg = errorDict[NSAppleScript.errorMessage] as? String ?? "<no message>"
                    NSLog("[mio-plugin-music] AppleScript error [\(tag)] \(num): \(msg)")
                }
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: result.stringValue)
        }
    }
}

/// Run an AppleScript where we don't care about the return value (transport
/// controls). Errors still respect the -600 / -1728 silence list.
func runAppleScriptFireAndForget(_ source: String, tag: String) {
    appleScriptQueue.async {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return }
        _ = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let num = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
            if num != -600 && num != -1728 {
                let msg = errorDict[NSAppleScript.errorMessage] as? String ?? "<no message>"
                NSLog("[mio-plugin-music] AppleScript error [\(tag)] \(num): \(msg)")
            }
        }
    }
}

/// Download image data asynchronously. Returns nil on any failure.
func downloadImage(from url: URL) async -> NSImage? {
    await withCheckedContinuation { continuation in
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else {
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: image)
        }.resume()
    }
}
