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
    private static let bundleId = "com.apple.Music"
    private static let sourceName = "Apple Music"

    // MARK: - Fetch

    static func fetch() async -> AppleScriptTrackInfo? {
        let script = """
        tell application "System Events"
            if not (exists process "Music") then return "NOT_RUNNING"
        end tell
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
