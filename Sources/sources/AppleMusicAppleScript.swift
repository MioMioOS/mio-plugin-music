//
//  AppleMusicAppleScript.swift
//  MioIsland Music Plugin
//
//  AppleScript bridge for the Music.app (macOS 10.15+). Compared to Spotify
//  the duration field is already in seconds, and artwork is exposed as raw
//  data rather than a URL so we have to ask for the "data size" and then
//  fish the bytes out separately. For simplicity we skip artwork here and
//  let MediaRemote (when available) or a future enhancement provide covers.
//

import AppKit

enum AppleMusicAppleScript {
    static let bundleId = "com.apple.Music"
    private static let sourceName = "Apple Music"

    /// Fast check: is Music.app actually running? When false, skip
    /// AppleScript — the 2s `with timeout` still trips but that's two
    /// wasted seconds per refresh when the user doesn't use Apple Music.
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleId
        }
    }

    // MARK: - Fetch

    static func fetch() async -> AppleScriptTrackInfo? {
        // Music.app occasionally stalls its AppleEvent handler (observed in
        // macOS 15.x when the app is mid-sync). Without an explicit timeout
        // each fetch inherits the 120-second default, which freezes the whole
        // source router for 2 minutes. `with timeout of 2 seconds` raises
        // errAETimeout (-1712) if Music doesn't respond quickly, and our
        // Swift layer turns that into nil so the router can move on.
        let script = """
        tell application "System Events"
            if not (exists process "Music") then return "NOT_RUNNING"
        end tell
        with timeout of 2 seconds
            tell application "Music"
                if player state is playing or player state is paused then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    set stateString to "PAUSED"
                    if player state is playing then set stateString to "PLAYING"
                    return stateString & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & trackDuration & "||" & trackPosition
                else
                    return "NOT_PLAYING"
                end if
            end tell
        end timeout
        """

        guard let raw = await runAppleScript(script, tag: "music") else { return nil }
        if raw == "NOT_RUNNING" || raw == "NOT_PLAYING" { return nil }

        let parts = raw.components(separatedBy: "||")
        guard parts.count >= 6 else { return nil }

        return AppleScriptTrackInfo(
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: TimeInterval(parts[4]) ?? 0,
            elapsedTime: TimeInterval(parts[5]) ?? 0,
            isPlaying: parts[0] == "PLAYING",
            artworkURL: nil,
            source: sourceName,
            bundleId: bundleId
        )
    }

    // MARK: - Artwork

    /// Apple Music stores artwork as embedded raw data (PNG/JPEG) rather than
    /// a URL. The cheapest way to pull it via AppleScript is to write the
    /// bytes to a temp file and load NSImage from it. The script writes to
    /// /tmp/mio-apple-music-art.dat (fixed path — overwrites each call).
    static func fetchArtwork() async -> NSImage? {
        let tmpPath = "/tmp/mio-plugin-music-current-art.dat"
        let script = """
        tell application "System Events"
            if not (exists process "Music") then return "NOT_RUNNING"
        end tell
        with timeout of 3 seconds
            tell application "Music"
                if player state is stopped then return "STOPPED"
                try
                    set artData to data of artwork 1 of current track
                    set f to open for access POSIX file "\(tmpPath)" with write permission
                    set eof f to 0
                    write artData to f
                    close access f
                    return "OK"
                on error errMsg
                    try
                        close access POSIX file "\(tmpPath)"
                    end try
                    return "NO_ARTWORK"
                end try
            end tell
        end timeout
        """
        guard let raw = await runAppleScript(script, tag: "music-art"),
              raw == "OK" else {
            return nil
        }
        let url = URL(fileURLWithPath: tmpPath)
        return await Task.detached { NSImage(contentsOf: url) }.value
    }

    // MARK: - Controls

    static func togglePlay() {
        runAppleScriptFireAndForget(
            "tell application \"Music\" to playpause",
            tag: "music-toggle"
        )
    }

    static func next() {
        runAppleScriptFireAndForget(
            "tell application \"Music\" to next track",
            tag: "music-next"
        )
    }

    static func previous() {
        runAppleScriptFireAndForget(
            "tell application \"Music\" to previous track",
            tag: "music-prev"
        )
    }

    static func seek(to time: TimeInterval) {
        let clamped = max(0, time)
        runAppleScriptFireAndForget(
            "tell application \"Music\" to set player position to \(clamped)",
            tag: "music-seek"
        )
    }
}
