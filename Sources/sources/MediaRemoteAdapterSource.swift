//
//  MediaRemoteAdapterSource.swift
//  MioIsland Music Plugin
//
//  Bypasses the macOS 15.4+ MRMediaRemoteGetNowPlayingInfo entitlement gate
//  by running `mediaremote-adapter.pl` (BSD-3-Clause, by Jonas van den Berg)
//  as a subprocess. The Perl script DynaLoader-loads the bundled
//  MediaRemoteAdapter.framework binary, which in turn links against Apple's
//  MediaRemote private framework. Because the entitlement check fires on the
//  CALLING symbol — which on Apple's side is MR internals, not our process
//  — the gate is skipped and we get the full now-playing payload.
//
//  The subprocess emits one JSON object per state change to stdout (diff
//  mode), debounced 50ms. We consume it line-by-line via a NSFileHandle read
//  observer and update the MediaRemoteInfo callback on the main queue.
//
//  Lifecycle:
//    - start() spawns the subprocess exactly once.
//    - On SIGPIPE / stdout EOF / non-zero exit, we retry after a 2-second
//      delay. After 3 consecutive crashes within 60s, we stop retrying and
//      let NowPlayingState fall back to the legacy source chain.
//    - stop() sends SIGTERM + waits up to 2s + SIGKILL if still alive.
//
//  Credits: MediaRemoteAdapter.framework + mediaremote-adapter.pl
//  Copyright (c) 2025 Jonas van den Berg. BSD-3-Clause.
//  Bundled under Resources/mediaremote-adapter/ in this plugin.
//

import AppKit
import Foundation

// MARK: - Stream payload (subset of adapter output)

/// Raw JSON shape emitted by the adapter in stream mode. Only the keys we
/// actually consume are decoded; the adapter also emits `contentItemIdentifier`,
/// `radioStationHash`, `timestamp`, etc. which we ignore.
private struct AdapterStreamPayload: Decodable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsedTime: Double?
    var playbackRate: Double?
    var playing: Bool?
    var bundleIdentifier: String?
    /// Base64-encoded artwork data. JSONDecoder automatically decodes
    /// when the Swift type is `Data` via default `.base64` strategy.
    var artworkData: Data?
}

// MARK: - Source

final class MediaRemoteAdapterSource {
    // Configuration
    private let scriptPath: String
    private let frameworkPath: String
    private let debounceMs: Int

    // Callback to NowPlayingState
    /// Called on the main queue whenever the subprocess emits a payload
    /// that results in a usable MediaRemoteInfo. Called with nil when the
    /// subprocess dies and restart is disabled.
    var onUpdate: ((MediaRemoteInfo) -> Void)?

    // Process state
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var lineBuffer = Data()

    // Aggregated "current state" — adapter sends diffs, so we merge them
    // ourselves. Apple Music frequently sends a playbackRate-only diff
    // when the user pauses, so we need to remember title/artist from earlier.
    private var currentInfo = MediaRemoteInfo()

    // Crash / restart tracking
    private var crashTimestamps: [Date] = []
    private let maxCrashesPer60s = 3
    private var restartWorkItem: DispatchWorkItem?
    private var stopped = false

    // MARK: - Init

    /// Initialises the source with paths resolved from the plugin bundle.
    /// Returns nil if either path is missing — caller should fall back to
    /// the legacy chain.
    init?() {
        // Resolve bundle that contains THIS source's compiled class. Using
        // Bundle(for:) instead of Bundle.main because the plugin loads into
        // the host's address space — Bundle.main is the host, not us.
        let bundle = Bundle(for: PathResolverToken.self)
        guard let script = bundle.path(forResource: "mediaremote-adapter",
                                        ofType: "pl",
                                        inDirectory: "mediaremote-adapter")
            ?? bundle.path(forResource: "mediaremote-adapter", ofType: "pl")
        else {
            NSLog("[mio-plugin-music] adapter script not found in bundle")
            return nil
        }
        let resourcesRoot = (script as NSString).deletingLastPathComponent
        let framework = (resourcesRoot as NSString)
            .appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: framework) else {
            NSLog("[mio-plugin-music] adapter framework not found at \(framework)")
            return nil
        }
        self.scriptPath = script
        self.frameworkPath = framework
        self.debounceMs = 50
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        stopped = false
        spawn()
    }

    func stop() {
        stopped = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        terminateProcess()
    }

    private func terminateProcess() {
        guard let proc = process else { return }
        process = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        if proc.isRunning {
            proc.terminate()
            // Give it 500ms to exit cleanly, then force.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
    }

    // MARK: - Spawn

    private func spawn() {
        guard !stopped else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [
            scriptPath,
            frameworkPath,
            "stream",
            "--debounce=\(debounceMs)"
        ]

        // Minimize inherited env — Perl / DynaLoader doesn't need our full
        // shell environment. Keep PATH so Perl can find its own modules.
        proc.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.handleTermination(status: p.terminationStatus) }
        }

        stdoutHandle = outPipe.fileHandleForReading
        stderrHandle = errPipe.fileHandleForReading

        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.ingestStdout(data) }
        }
        stderrHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                NSLog("[mio-plugin-music] adapter stderr: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            _ = self
        }

        do {
            try proc.run()
            process = proc
            NSLog("[mio-plugin-music] adapter spawned pid=\(proc.processIdentifier)")
        } catch {
            NSLog("[mio-plugin-music] adapter spawn failed: \(error)")
            scheduleRestart()
        }
    }

    // MARK: - Stdout ingestion

    private func ingestStdout(_ chunk: Data) {
        lineBuffer.append(chunk)
        // Adapter emits newline-delimited JSON. Parse as many complete
        // lines as the buffer currently holds.
        while let nlRange = lineBuffer.firstRange(of: Data([0x0A])) {
            let lineData = lineBuffer.prefix(upTo: nlRange.lowerBound)
            lineBuffer.removeSubrange(0 ..< nlRange.upperBound)
            guard !lineData.isEmpty else { continue }
            parseLine(Data(lineData))
        }
    }

    private func parseLine(_ data: Data) {
        do {
            let payload = try JSONDecoder().decode(AdapterStreamPayload.self, from: data)
            merge(payload)
            if currentInfo.hasTrack {
                onUpdate?(currentInfo)
            }
        } catch {
            // Not every line is a full object — stream mode sometimes emits
            // null or empty diff when source goes away. Silent on DecodingError
            // unless it looks like a real crash (non-JSON prefix).
            if let preview = String(data: data.prefix(60), encoding: .utf8),
               !preview.hasPrefix("{") && !preview.hasPrefix("null") {
                NSLog("[mio-plugin-music] adapter: unparseable line: \(preview)")
            }
        }
    }

    /// Merge an adapter diff into `currentInfo`. Only overwrite fields that
    /// the payload explicitly provided — leave the rest at their previous
    /// value so a "just the elapsed time changed" diff doesn't erase title.
    private func merge(_ payload: AdapterStreamPayload) {
        if let title = payload.title { currentInfo.title = title }
        if let artist = payload.artist { currentInfo.artist = artist }
        if let album = payload.album { currentInfo.album = album }
        if let duration = payload.duration { currentInfo.duration = duration }
        if let elapsed = payload.elapsedTime { currentInfo.elapsedTime = elapsed }
        if let rate = payload.playbackRate { currentInfo.playbackRate = rate }
        if let playing = payload.playing {
            currentInfo.isPlaying = playing
        } else if let rate = payload.playbackRate {
            // Some diffs only ship playbackRate; derive isPlaying.
            currentInfo.isPlaying = rate > 0
        }
        if let bid = payload.bundleIdentifier { currentInfo.bundleIdentifier = bid }
        if let art = payload.artworkData, !art.isEmpty {
            currentInfo.artwork = NSImage(data: art)
        }
    }

    // MARK: - Termination / restart

    private func handleTermination(status: Int32) {
        NSLog("[mio-plugin-music] adapter terminated (status=\(status))")
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        process = nil
        currentInfo = MediaRemoteInfo()
        lineBuffer.removeAll()
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        let now = Date()
        crashTimestamps.append(now)
        crashTimestamps.removeAll { now.timeIntervalSince($0) > 60 }
        if crashTimestamps.count > maxCrashesPer60s {
            NSLog("[mio-plugin-music] adapter crashed \(crashTimestamps.count) times in 60s — giving up")
            return
        }
        // Exponential-ish backoff: 1s, 2s, 4s by crash count within the window.
        let delay = min(4.0, pow(2.0, Double(crashTimestamps.count - 1)))
        let work = DispatchWorkItem { [weak self] in self?.spawn() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Transport (fire-and-forget short-lived subprocess)

    /// Send a MediaRemote command ID. Uses a short-lived subprocess
    /// rather than a persistent control channel — keeps the architecture
    /// simple and matches how Atoll does it.
    /// Known commands (MRCommand IDs per adapter Perl examples):
    ///   0=play, 1=pause, 2=togglePlayPause, 3=stop, 4=next, 5=previous
    func sendCommand(_ id: Int) {
        runOneShot(["send", String(id)])
    }

    /// Seek to position in seconds. Adapter takes microseconds, so *1e6.
    func seek(_ seconds: Double) {
        let micros = Int64(max(0, seconds) * 1_000_000)
        runOneShot(["seek", String(micros)])
    }

    private func runOneShot(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [scriptPath, frameworkPath] + args
        proc.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let devnull = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardOutput = devnull
        proc.standardError = devnull
        do {
            try proc.run()
        } catch {
            NSLog("[mio-plugin-music] adapter one-shot failed: \(error)")
        }
    }
}

// Dummy class used only as a `Bundle(for:)` anchor so we can find our own
// plugin bundle without relying on Bundle.main (which is the host app).
private final class PathResolverToken {}
