//
//  MediaRemoteSource.swift
//  MioIsland Music Plugin
//
//  Dynamically loads /System/Library/PrivateFrameworks/MediaRemote.framework
//  so we can read system Now Playing info without linking a private API.
//
//  Known caveat on macOS 15.4+: Apple restricted MRMediaRemoteGetNowPlayingInfo
//  to callers with a specific entitlement. For regular third party apps the
//  callback returns an empty dictionary. When this happens we surface the
//  empty result and NowPlayingState falls through to AppleScript sources.
//

import AppKit

// MARK: - MediaRemote function signatures

private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction =
    @convention(c) (DispatchQueue) -> Void
private typealias MRMediaRemoteGetNowPlayingInfoFunction =
    @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction =
    @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
private typealias MRMediaRemoteSendCommandFunction =
    @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
private typealias MRMediaRemoteSetElapsedTimeFunction =
    @convention(c) (Double) -> Void

// MARK: - Command enum (public API of this file)

enum MediaRemoteCommand: UInt32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
}

// MARK: - Payload struct

struct MediaRemoteInfo {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artwork: NSImage?
    var duration: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var playbackRate: Double = 0
    var isPlaying: Bool = false
    var bundleIdentifier: String = ""

    var hasTrack: Bool { !title.isEmpty }
}

// MARK: - Info dictionary keys

private let kTitle = "kMRMediaRemoteNowPlayingInfoTitle"
private let kArtist = "kMRMediaRemoteNowPlayingInfoArtist"
private let kAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
private let kArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
private let kDuration = "kMRMediaRemoteNowPlayingInfoDuration"
private let kElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
private let kPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

// MARK: - Source

final class MediaRemoteSource {
    private var handle: UnsafeMutableRawPointer?
    private var registerFn: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private var getInfoFn: MRMediaRemoteGetNowPlayingInfoFunction?
    private var getIsPlayingFn: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction?
    private var sendCommandFn: MRMediaRemoteSendCommandFunction?
    private var setElapsedTimeFn: MRMediaRemoteSetElapsedTimeFunction?

    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        loadFramework()
    }

    deinit {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        if let handle {
            dlclose(handle)
        }
    }

    // MARK: - Loading

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let h = dlopen(path, RTLD_NOW) else {
            NSLog("[mio-plugin-music] MediaRemote dlopen failed")
            return
        }
        handle = h

        if let sym = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerFn = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") {
            getInfoFn = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlayingFn = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteSendCommand") {
            sendCommandFn = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunction.self)
        }
        if let sym = dlsym(h, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFn = unsafeBitCast(sym, to: MRMediaRemoteSetElapsedTimeFunction.self)
        }
    }

    // MARK: - Public API

    /// Pull the current Now Playing dictionary. completion runs on the main queue.
    /// On macOS 15.4+ the callback may deliver an empty dict; caller should
    /// treat a nil MediaRemoteInfo (or one where hasTrack is false) as a miss.
    func fetchInfo(completion: @escaping (MediaRemoteInfo?) -> Void) {
        guard let getInfoFn else {
            completion(nil)
            return
        }

        getInfoFn(DispatchQueue.main) { dict in
            guard !dict.isEmpty else {
                completion(nil)
                return
            }

            var info = MediaRemoteInfo()
            info.title = dict[kTitle] as? String ?? ""
            info.artist = dict[kArtist] as? String ?? ""
            info.album = dict[kAlbum] as? String ?? ""
            info.duration = dict[kDuration] as? TimeInterval ?? 0
            info.elapsedTime = dict[kElapsedTime] as? TimeInterval ?? 0
            info.playbackRate = dict[kPlaybackRate] as? Double ?? 0
            info.isPlaying = info.playbackRate > 0

            if let data = dict[kArtworkData] as? Data {
                info.artwork = NSImage(data: data)
            }

            // Title empty and no artwork means MediaRemote returned a stale /
            // blocked payload. Treat as miss.
            if info.title.isEmpty {
                completion(nil)
            } else {
                completion(info)
            }
        }
    }

    /// Fire and forget control command.
    func sendCommand(_ cmd: MediaRemoteCommand) {
        guard let sendCommandFn else { return }
        _ = sendCommandFn(cmd.rawValue, nil)
    }

    /// Adjust the playhead position of whatever is currently playing.
    func setElapsedTime(_ t: TimeInterval) {
        setElapsedTimeFn?(max(0, t))
    }

    /// Register for MediaRemote change notifications. The closure is dispatched
    /// on the main queue so callers can touch UI state directly.
    func registerForNotifications(onChange: @escaping () -> Void) {
        registerFn?(DispatchQueue.main)

        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"
        ]

        let center = NotificationCenter.default
        for raw in names {
            let token = center.addObserver(
                forName: NSNotification.Name(raw),
                object: nil,
                queue: .main
            ) { _ in
                onChange()
            }
            notificationObservers.append(token)
        }
    }
}
