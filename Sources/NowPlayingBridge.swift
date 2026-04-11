//
//  NowPlayingBridge.swift
//  MioIsland Music Plugin
//
//  Reads system Now Playing info via private MediaRemote.framework.
//  Dynamically loads the framework to avoid linking against private APIs.
//

import AppKit
import Combine

struct NowPlayingInfo {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artwork: NSImage?
    var duration: Double = 0
    var elapsedTime: Double = 0
    var isPlaying: Bool = false
    var bundleId: String?  // source app
}

@MainActor
final class NowPlayingBridge: ObservableObject {
    static let shared = NowPlayingBridge()

    @Published var info = NowPlayingInfo()

    // MediaRemote function pointers
    private var MRMediaRemoteGetNowPlayingInfo: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)?
    private var MRMediaRemoteSendCommand: (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool)?
    private var MRMediaRemoteRegisterForNowPlayingNotifications: (@convention(c) (DispatchQueue) -> Void)?

    private var timer: Timer?

    init() {
        loadMediaRemote()
    }

    // MARK: - Load Private Framework

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else { return }

        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteSendCommand") {
            MRMediaRemoteSendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool).self)
        }
        if let ptr = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            MRMediaRemoteRegisterForNowPlayingNotifications = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue) -> Void).self)
        }
    }

    // MARK: - Start / Stop

    func start() {
        // Register for notifications
        MRMediaRemoteRegisterForNowPlayingNotifications?(DispatchQueue.main)

        // Listen for changes
        let nc = NotificationCenter.default
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        ]
        for name in names {
            nc.addObserver(self, selector: #selector(nowPlayingChanged), name: NSNotification.Name(name), object: nil)
        }

        // Also poll every 2 seconds for elapsed time updates
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchNowPlaying() }
        }

        // Initial fetch
        fetchNowPlaying()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func nowPlayingChanged() {
        Task { @MainActor in fetchNowPlaying() }
    }

    // MARK: - Fetch

    private func fetchNowPlaying() {
        MRMediaRemoteGetNowPlayingInfo?(DispatchQueue.main) { [weak self] dict in
            Task { @MainActor in
                guard let self else { return }
                var info = NowPlayingInfo()
                info.title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                info.artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                info.album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                info.duration = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
                info.elapsedTime = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
                info.isPlaying = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0

                if let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                    info.artwork = NSImage(data: artworkData)
                }

                self.info = info
            }
        }
    }

    // MARK: - Controls (command IDs from MediaRemote.h)

    func togglePlayPause() {
        _ = MRMediaRemoteSendCommand?(2, nil) // kMRTogglePlayPause
    }

    func nextTrack() {
        _ = MRMediaRemoteSendCommand?(4, nil) // kMRNextTrack
    }

    func previousTrack() {
        _ = MRMediaRemoteSendCommand?(5, nil) // kMRPreviousTrack
    }
}
