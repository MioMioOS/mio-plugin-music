//
//  SpotifyAppleScript.swift
//  MioIsland Music Plugin
//
//  AppleScript bridge for the Spotify desktop app. Spotify exposes a rich
//  scripting dictionary so we can pull title / artist / album / duration /
//  position and drive transport controls. Artwork URL is also scriptable
//  which makes this cheaper than any other source.
//
//  Threading: all scripts run on a background queue via runAppleScript.
//  NSAppleScript is NOT safe to share across threads; each call creates a
//  fresh instance. Duration from Spotify is in milliseconds (we divide by
//  1000 inside the script) and player position is in seconds.
//

import AppKit

struct AppleScriptTrackInfo {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsedTime: TimeInterval
    var isPlaying: Bool
    var artworkURL: String?
    var source: String         // "Spotify" / "Apple Music"
    var bundleId: String
}

enum SpotifyAppleScript {
    private static let bundleId = "com.spotify.client"
    private static let sourceName = "Spotify"

    // MARK: - Fetch

    static func fetch() async -> AppleScriptTrackInfo? {
        let script = """
        tell application "System Events"
            if not (exists process "Spotify") then return "NOT_RUNNING"
        end tell
        tell application "Spotify"
            if player state is playing or player state is paused then
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set stateString to "PAUSED"
                if player state is playing then set stateString to "PLAYING"
                set artURL to ""
                try
                    set artURL to artwork url of current track
                end try
                return stateString & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & (trackDuration / 1000) & "||" & trackPosition & "||" & artURL
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let raw = await runAppleScript(script, tag: "spotify") else { return nil }
        if raw == "NOT_RUNNING" || raw == "NOT_PLAYING" { return nil }

        let parts = raw.components(separatedBy: "||")
        guard parts.count >= 6 else { return nil }

        let isPlaying = parts[0] == "PLAYING"
        let artURL = parts.count >= 7 ? parts[6] : ""

        return AppleScriptTrackInfo(
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: TimeInterval(parts[4]) ?? 0,
            elapsedTime: TimeInterval(parts[5]) ?? 0,
            isPlaying: isPlaying,
            artworkURL: artURL.isEmpty ? nil : artURL,
            source: sourceName,
            bundleId: bundleId
        )
    }

    // MARK: - Artwork

    static func fetchArtwork() async -> NSImage? {
        let script = """
        tell application "System Events"
            if not (exists process "Spotify") then return ""
        end tell
        tell application "Spotify"
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """
        guard let urlString = await runAppleScript(script, tag: "spotify-art"),
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return await downloadImage(from: url)
    }

    // MARK: - Controls

    static func togglePlay() {
        runAppleScriptFireAndForget(
            "tell application \"Spotify\" to playpause",
            tag: "spotify-toggle"
        )
    }

    static func next() {
        runAppleScriptFireAndForget(
            "tell application \"Spotify\" to next track",
            tag: "spotify-next"
        )
    }

    static func previous() {
        runAppleScriptFireAndForget(
            "tell application \"Spotify\" to previous track",
            tag: "spotify-prev"
        )
    }

    static func seek(to time: TimeInterval) {
        let clamped = max(0, time)
        runAppleScriptFireAndForget(
            "tell application \"Spotify\" to set player position to \(clamped)",
            tag: "spotify-seek"
        )
    }
}
