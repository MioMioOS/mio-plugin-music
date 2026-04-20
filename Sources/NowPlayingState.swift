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
    /// Atoll-style MediaRemoteAdapter subprocess stream — bypasses the
    /// macOS 15.4+ entitlement gate and gives us real-time system Now
    /// Playing with artwork, duration, and elapsed time.
    case mediaRemoteAdapter
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
    /// Atoll-style subprocess adapter. Optional because the bundle may be
    /// missing the Resources/mediaremote-adapter payload (dev builds, old
    /// plugin versions). When non-nil, it becomes the primary source and
    /// most of the legacy polling / AppleScript chain stays dormant.
    private let mediaRemoteAdapter: MediaRemoteAdapterSource? = MediaRemoteAdapterSource()
    private var pollTimer: Timer?
    private var playbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var stickySource: NowPlayingSourceKind = .none
    private var lastChromeTabURL: String = ""
    private var isRunning = false
    private var refreshInFlight = false

    /// macOS 15.4+ gates MRMediaRemoteGetNowPlayingInfo behind a private
    /// entitlement. When the call returns an empty dict we mark the API
    /// as blocked and skip it for 60 seconds before retrying (macOS minor
    /// updates can flip the entitlement state, so we don't mark "blocked
    /// forever"). Saves ~50ms per refresh when blocked, but more importantly
    /// lets the router hit AppleScript on the first pass instead of the
    /// second — ~1s faster cold start on restricted systems.
    private var mediaRemoteBlockedUntil: Date?

    /// NSWorkspace observers for app launch/terminate. When a music app
    /// opens or closes, refresh immediately — these events beat the poll
    /// timer by several seconds.
    private var workspaceObservers: [NSObjectProtocol] = []

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

        // Start the Atoll-style adapter subprocess if bundled. This is
        // the PRIMARY low-latency source — on 15.4+ it's the only one that
        // actually produces live data without AppleScript polling. When
        // it emits, we short-circuit the router entirely.
        if let adapter = mediaRemoteAdapter {
            adapter.onUpdate = { [weak self] info in
                Task { @MainActor in self?.applyAdapterUpdate(info) }
            }
            adapter.start()
        }

        // Observe Spotify distributed notifications for instant reaction.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )

        // Observe Apple Music. macOS 15+ Music.app emits
        // com.apple.Music.playerInfo; older iTunes emitted
        // com.apple.iTunes.playerInfo. Register both so track changes are
        // picked up instantly regardless of which one the current build
        // broadcasts.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(musicStateChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(musicStateChanged),
            name: NSNotification.Name("com.apple.iTunes.playerInfo"),
            object: nil
        )

        // Observe app launch / terminate — when Spotify or Music opens, we
        // want to detect it within the same RunLoop tick rather than waiting
        // out the 15s safety-net poll.
        let wsCenter = NSWorkspace.shared.notificationCenter
        let trackedBundleIds: Set<String> = [
            SpotifyAppleScript.bundleId,
            AppleMusicAppleScript.bundleId,
            ChromeWebSource.bundleId,
        ]
        let launchToken = wsCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                trackedBundleIds.contains(bid)
            else { return }
            Task { @MainActor in self?.refresh() }
        }
        let terminateToken = wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier,
                trackedBundleIds.contains(bid)
            else { return }
            Task { @MainActor in self?.refresh() }
        }
        workspaceObservers = [launchToken, terminateToken]

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

        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        mediaRemoteAdapter?.stop()
    }

    @objc private func spotifyStateChanged() {
        Task { @MainActor in self.refresh() }
    }

    @objc private func musicStateChanged() {
        Task { @MainActor in self.refresh() }
    }

    // MARK: - Polling

    private func startPolling() {
        rearmPoll()
    }

    /// Adaptive poll interval — the event-driven fast paths aren't uniformly
    /// reliable across players on modern macOS:
    ///   - Spotify: com.spotify.client.PlaybackStateChanged fires instantly
    ///     on every track change → 10s safety-net is plenty.
    ///   - Apple Music: com.apple.Music.playerInfo is NOT reliably broadcast
    ///     on macOS 14+ (Apple stopped posting it in many builds). Combined
    ///     with MediaRemote's 15.4+ entitlement gate, there is literally no
    ///     event source left, so we have to poll. 0.8s gets track changes
    ///     visible inside 1s which is the best we can do without the
    ///     Atoll-style adapter framework.
    ///   - Chrome / web players: no notifications at all. 1.2s poll is a
    ///     reasonable tradeoff between latency and CPU.
    ///   - Idle / nothing playing: 10s is fine — the NSWorkspace launch
    ///     observer will wake us instantly when a music app opens.
    /// Recomputed and re-armed every time `stickySource` or `isPlaying`
    /// changes, so the plugin idles cheaply until it has something to track.
    private var currentPollInterval: TimeInterval = 10.0

    private func adaptivePollInterval() -> TimeInterval {
        switch stickySource {
        // Adapter subprocess pushes data in real time — poll only as a
        // last-resort safety net in case the subprocess silently wedges.
        case .mediaRemoteAdapter:         return 30.0
        case .appleMusic where isPlaying: return 0.8
        case .chrome where isPlaying:     return 1.2
        case .spotify where isPlaying:    return 3.0 // event-driven, poll is just backup
        case .mediaRemote where isPlaying: return 3.0
        default: return 10.0
        }
    }

    private func rearmPoll() {
        let newInterval = adaptivePollInterval()
        // Avoid invalidating the timer on every refresh when the interval
        // didn't actually change — Timer allocs aren't free and the router
        // calls rearmPoll() after every successful fetch.
        if let t = pollTimer, t.isValid, abs(newInterval - currentPollInterval) < 0.01 {
            return
        }
        pollTimer?.invalidate()
        currentPollInterval = newInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: newInterval, repeats: true) { [weak self] _ in
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
        // Adapter short-circuit: when the subprocess is the sticky source
        // and we already have a track from it, there's nothing to do here —
        // new data will arrive via `applyAdapterUpdate(_:)` whenever it
        // actually changes. Polling on top of an event-driven source just
        // wastes AppleScript round-trips.
        if stickySource == .mediaRemoteAdapter,
           !title.isEmpty,
           mediaRemoteAdapter != nil {
            return
        }

        // Running-app snapshot — read once per pass so we don't hit the
        // workspace API four times.
        let spotifyRunning = SpotifyAppleScript.isRunning
        let musicRunning = AppleMusicAppleScript.isRunning
        let chromeRunning = ChromeWebSource.isRunning

        // MediaRemote gate: on macOS 15.4+ the call returns an empty dict
        // without entitlement. Cache that for 60s so we don't keep eating
        // an IPC round-trip per refresh.
        let now = Date()
        let mrBlocked: Bool
        if let until = mediaRemoteBlockedUntil, until > now {
            mrBlocked = true
        } else {
            mrBlocked = false
        }

        // Sticky-source fast path — if the last successful source is still
        // a live candidate, try it alone first. One AppleScript round-trip
        // when music is playing = lowest possible latency path.
        if stickySource != .none, isCandidateLive(
            stickySource,
            spotifyRunning: spotifyRunning,
            musicRunning: musicRunning,
            chromeRunning: chromeRunning,
            mrBlocked: mrBlocked,
            allowAppleScript: allowAppleScript
        ) {
            if let used = await tryFetch(stickySource) {
                await MainActor.run {
                    self.stickySource = used
                    self.updatePlaybackTimer()
                    self.rearmPoll()
                }
                return
            }
        }

        // Parallel fallback probing. `async let` fans out all live candidates
        // concurrently — cold start used to serialize: try MR (~50ms, miss on
        // 15.4+) → try Spotify AppleScript (~100-2000ms) → try Music (~100-2000ms)
        // → try Chrome (~200ms+). Worst case ~6s. Now they all race and we
        // use the first non-nil result by priority.
        async let mrResult: MediaRemoteInfo? = mrBlocked ? nil : mediaRemoteFetch()
        async let spotifyResult: AppleScriptTrackInfo? = (allowAppleScript && spotifyRunning)
            ? SpotifyAppleScript.fetch() : nil
        async let musicResult: AppleScriptTrackInfo? = (allowAppleScript && musicRunning)
            ? AppleMusicAppleScript.fetch() : nil
        async let chromeResult: ChromeTrackInfo? = (allowAppleScript && chromeRunning)
            ? ChromeWebSource.fetch() : nil

        let mr = await mrResult
        let sp = await spotifyResult
        let mu = await musicResult
        let ch = await chromeResult

        // MediaRemote returning empty on 15.4+ marks it blocked for 60s.
        if !mrBlocked, mr == nil, mediaRemoteLikelyBlocked() {
            await MainActor.run {
                self.mediaRemoteBlockedUntil = Date().addingTimeInterval(60)
            }
        }

        // Priority order for picking the winner among the parallel results.
        // MediaRemote first (it unifies everything when available). Then
        // Spotify > Apple Music > Chrome — Spotify desktop tends to have
        // fuller metadata than web, and Apple Music's AppleScript is slower
        // so it gets slight demotion when a competing hit exists.
        if let info = mr, info.hasTrack {
            await MainActor.run {
                self.apply(mediaRemote: info)
                self.stickySource = .mediaRemote
                self.updatePlaybackTimer()
                self.rearmPoll()
            }
            return
        }
        if let info = sp, !info.title.isEmpty {
            await MainActor.run {
                self.apply(appleScript: info)
                self.stickySource = .spotify
                self.updatePlaybackTimer()
                self.rearmPoll()
            }
            if self.albumArt == nil, let art = await SpotifyAppleScript.fetchArtwork() {
                await MainActor.run { self.albumArt = art }
            }
            return
        }
        if let info = mu, !info.title.isEmpty {
            await MainActor.run {
                self.apply(appleScript: info)
                self.stickySource = .appleMusic
                self.updatePlaybackTimer()
                self.rearmPoll()
            }
            if self.albumArt == nil, let art = await AppleMusicAppleScript.fetchArtwork() {
                await MainActor.run { self.albumArt = art }
            }
            return
        }
        if let info = ch, !info.title.isEmpty {
            await MainActor.run {
                self.apply(chrome: info)
                self.stickySource = .chrome
                self.updatePlaybackTimer()
                self.rearmPoll()
            }
            if let artURL = info.artworkURL, let url = URL(string: artURL) {
                if let image = await downloadImage(from: url) {
                    await MainActor.run { self.albumArt = image }
                }
            }
            return
        }

        // Nothing returned a hit; clear state.
        await MainActor.run {
            self.clearTrack()
            self.stickySource = .none
            self.updatePlaybackTimer()
            self.rearmPoll()
        }
    }

    /// Whether a source could plausibly produce a hit right now given the
    /// running-app snapshot + MediaRemote blocked state. Used to short-circuit
    /// the sticky-source fast path — don't probe Spotify if Spotify is closed.
    private func isCandidateLive(
        _ kind: NowPlayingSourceKind,
        spotifyRunning: Bool,
        musicRunning: Bool,
        chromeRunning: Bool,
        mrBlocked: Bool,
        allowAppleScript: Bool
    ) -> Bool {
        switch kind {
        case .none: return false
        case .mediaRemoteAdapter: return false // push-only, not candidate for pull-fetch
        case .mediaRemote: return !mrBlocked
        case .spotify: return allowAppleScript && spotifyRunning
        case .appleMusic: return allowAppleScript && musicRunning
        case .chrome: return allowAppleScript && chromeRunning
        }
    }

    /// Bridge the MediaRemote callback-style API to async/await so we can
    /// fan it out alongside the AppleScript sources in `routeSources`.
    private func mediaRemoteFetch() async -> MediaRemoteInfo? {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                self.mediaRemote.fetchInfo { cont.resume(returning: $0) }
            }
        }
    }

    /// Heuristic for "MediaRemote returned empty because Apple blocked us,
    /// not because no one is playing". If at least one of the known player
    /// apps is running but MediaRemote came back nil, the cause is almost
    /// certainly the 15.4+ entitlement gate.
    private func mediaRemoteLikelyBlocked() -> Bool {
        SpotifyAppleScript.isRunning ||
        AppleMusicAppleScript.isRunning ||
        ChromeWebSource.isRunning
    }

    /// Try a single source. Returns the source kind on success, nil on miss.
    private func tryFetch(_ kind: NowPlayingSourceKind) async -> NowPlayingSourceKind? {
        switch kind {
        case .none:
            return nil

        case .mediaRemoteAdapter:
            // Push-only source; pull-fetch is a no-op.
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
            // Apple Music doesn't expose an artwork URL via AppleScript;
            // we dump the raw bytes to /tmp and reload. Only refetch when
            // the track identity actually changes to avoid hammering disk.
            if self.albumArt == nil, let art = await AppleMusicAppleScript.fetchArtwork() {
                await MainActor.run { self.albumArt = art }
            }
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

    /// Called when the Atoll-style subprocess adapter emits a fresh payload.
    /// This bypasses the full router — adapter updates are the truest signal
    /// we have on 15.4+, so we claim sticky-source and publish straight away.
    private func applyAdapterUpdate(_ info: MediaRemoteInfo) {
        self.title = info.title
        self.artist = info.artist
        self.album = info.album
        self.duration = info.duration
        self.elapsedTime = info.elapsedTime
        self.isPlaying = info.isPlaying
        if let art = info.artwork {
            self.albumArt = art
        }
        // Source name from bundle id for the UI chip. Apple Music → "Apple Music"
        // etc. Unknown bundle ids fall back to generic "System Media".
        self.sourceBundleId = info.bundleIdentifier
        self.sourceName = Self.humanReadableSource(bundleId: info.bundleIdentifier)
        self.lastChromeTabURL = ""
        self.stickySource = .mediaRemoteAdapter
        self.updatePlaybackTimer()
        self.rearmPoll()
    }

    private static func humanReadableSource(bundleId: String) -> String {
        switch bundleId {
        case "com.apple.Music":                    return "Apple Music"
        case "com.spotify.client":                 return "Spotify"
        case "com.google.Chrome":                  return "Chrome"
        case "com.apple.Safari":                   return "Safari"
        case "com.microsoft.edgemac":              return "Edge"
        case "com.apple.podcasts":                 return "Podcasts"
        case "com.apple.tv":                       return "Apple TV"
        default:
            return bundleId.components(separatedBy: ".").last?.capitalized ?? "System Media"
        }
    }

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
        // Track changed → drop cached artwork so the source can refetch
        // (Spotify does URL-based, Apple Music does raw-bytes-via-temp-file).
        if self.title != info.title || self.artist != info.artist {
            self.albumArt = nil
        }
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
        rearmPoll() // isPlaying flipped → maybe change poll cadence

        switch stickySource {
        case .mediaRemoteAdapter:
            mediaRemoteAdapter?.sendCommand(2) // kMRATogglePlayPause
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
        scheduleRefresh(after: 0.1)
    }

    func nextTrack() {
        switch stickySource {
        case .mediaRemoteAdapter:
            mediaRemoteAdapter?.sendCommand(4) // kMRANextTrack
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
        scheduleRefresh(after: 0.1)
    }

    func previousTrack() {
        switch stickySource {
        case .mediaRemoteAdapter:
            mediaRemoteAdapter?.sendCommand(5) // kMRAPreviousTrack
        case .spotify:
            SpotifyAppleScript.previous()
        case .appleMusic:
            AppleMusicAppleScript.previous()
        case .chrome:
            mediaRemote.sendCommand(.previousTrack)
        case .mediaRemote, .none:
            mediaRemote.sendCommand(.previousTrack)
        }
        scheduleRefresh(after: 0.1)
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        elapsedTime = clamped
        updatePlaybackTimer()

        switch stickySource {
        case .mediaRemoteAdapter:
            mediaRemoteAdapter?.seek(clamped)
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

        scheduleRefresh(after: 0.1)
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
                // Silence known-expected error codes:
                //   -600  = application not running
                //   -1712 = errAETimeout (our `with timeout of N seconds` firing)
                //   -1728 = AEError, generic Apple Event descriptor issue
                if num != -600 && num != -1712 && num != -1728 {
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
