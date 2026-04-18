//
//  ChromeWebSource.swift
//  MioIsland Music Plugin
//
//  Reads media state from Google Chrome tabs by injecting JavaScript via
//  the Chrome AppleScript "execute javascript" command. The user must have
//  Chrome's View > Developer > "Allow JavaScript from Apple Events" toggle
//  enabled; otherwise the script silently returns nothing and we treat the
//  source as unavailable rather than surfacing an error.
//
//  Also handles:
//    - YouTube title parsing ("Song - Artist - YouTube")
//    - YouTube thumbnail fallback (img.youtube.com)
//    - Site-aware source naming (YouTube / YouTube Music / SoundCloud /
//      Spotify Web / Google Chrome)
//

import AppKit

struct ChromeTrackInfo {
    var title: String
    var artist: String
    var duration: TimeInterval
    var elapsedTime: TimeInterval
    var isPlaying: Bool
    var sourceName: String
    var tabURL: String
    var artworkURL: String?
}

enum ChromeWebSource {
    static let bundleId = "com.google.Chrome"

    // MARK: - Fetch

    static func fetch() async -> ChromeTrackInfo? {
        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set playingTitle to ""
            set playingURL to ""
            set playingInfo to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set mediaInfo to execute t javascript "
                            (function() {
                                var media = Array.from(document.querySelectorAll('video,audio'));
                                if (!media.length) return 'NO_MEDIA';
                                var active = media.find(function(item) { return !item.paused && !item.ended; });
                                var candidate = active || media.find(function(item) { return !item.ended; }) || media[0];
                                if (!candidate) return 'NO_MEDIA';
                                var metaImage = document.querySelector('meta[property=\\"og:image\\"], meta[name=\\"twitter:image\\"], link[rel=\\"image_src\\"]');
                                var thumbnail = candidate.poster || (metaImage ? (metaImage.content || metaImage.href || '') : '');
                                return (active ? 'PLAYING' : 'PAUSED') + '||' + candidate.currentTime + '||' + candidate.duration + '||' + thumbnail;
                            })();
                        "
                        if mediaInfo starts with "PLAYING||" then
                            set playingTitle to title of t
                            set playingURL to URL of t
                            set playingInfo to mediaInfo
                            exit repeat
                        end if
                    end try
                end repeat
                if playingURL is not "" then exit repeat
            end repeat
            if playingURL is not "" then return "PLAYING_TAB||" & playingTitle & "||" & playingURL & "||" & playingInfo
            return "NOT_FOUND"
        end tell
        """

        guard let raw = await runAppleScript(script, tag: "chrome") else { return nil }
        if raw == "NOT_RUNNING" || raw == "NOT_FOUND" { return nil }

        let parts = raw.components(separatedBy: "||")
        guard parts.count >= 5 else { return nil }

        // Layout from script:
        // [0] PLAYING_TAB
        // [1] raw tab title
        // [2] tab URL
        // [3] PLAYING / PAUSED
        // [4] currentTime
        // [5] duration
        // [6] thumbnail (optional)

        let rawTitle = parts[1]
        let url = parts[2]
        let state = parts[3]
        let elapsed = parts.count >= 5 ? TimeInterval(parts[4]) ?? 0 : 0
        let duration = parts.count >= 6 ? TimeInterval(parts[5]) ?? 0 : 0
        let artwork = parts.count >= 7 ? parts[6] : ""

        let parsed = parseYouTubeTitle(rawTitle)
        let sourceName = chromeSourceName(for: url)

        var artworkURL: String? = artwork.isEmpty ? nil : artwork
        if artworkURL == nil, url.contains("youtube.com"),
           let videoID = extractYouTubeVideoID(from: url) {
            artworkURL = "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"
        }

        return ChromeTrackInfo(
            title: parsed.title,
            artist: parsed.artist,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: state == "PLAYING",
            sourceName: sourceName,
            tabURL: url,
            artworkURL: artworkURL
        )
    }

    // MARK: - Controls (play/pause via JS; next/prev unsupported without site specific hooks)

    static func togglePlay(shouldPlay: Bool, preferredURL: String?) async -> Bool {
        let js = controlJavaScript(shouldPlay: shouldPlay)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPreferred = escapeAppleScriptString(preferredURL ?? "")

        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set preferredURL to "\(escapedPreferred)"
            if preferredURL is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is preferredURL then
                            try
                                set actionResult to execute t javascript "\(js)"
                                if actionResult is "OK" then return "OK"
                            end try
                        end if
                    end repeat
                end repeat
            end if
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set actionResult to execute t javascript "\(js)"
                        if actionResult is "OK" then return "OK"
                    end try
                end repeat
            end repeat
            return "NO_MEDIA"
        end tell
        """

        guard let result = await runAppleScript(script, tag: "chrome-toggle") else { return false }
        return result == "OK"
    }

    static func seek(to time: TimeInterval, preferredURL: String?) async -> Bool {
        let clamped = max(0, time)
        let js = """
        (function() {
            var media = Array.from(document.querySelectorAll('video,audio'));
            if (!media.length) return 'NO_MEDIA';
            var target = media.find(function(item) { return !item.ended; }) || media[0];
            if (!target) return 'NO_MEDIA';
            try {
                target.currentTime = \(clamped);
                return 'OK';
            } catch (error) {
                return 'ERROR';
            }
        })();
        """
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

        let escapedPreferred = escapeAppleScriptString(preferredURL ?? "")
        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set preferredURL to "\(escapedPreferred)"
            if preferredURL is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is preferredURL then
                            try
                                set actionResult to execute t javascript "\(js)"
                                if actionResult is "OK" then return "OK"
                            end try
                        end if
                    end repeat
                end repeat
            end if
            return "NO_MEDIA"
        end tell
        """

        guard let result = await runAppleScript(script, tag: "chrome-seek") else { return false }
        return result == "OK"
    }

    // MARK: - Parsing helpers

    /// Parse YouTube tab titles. Formats seen in the wild:
    ///   "Song Name - Artist - YouTube"
    ///   "Song Name - YouTube"
    ///   "(123) Song Name - Artist - YouTube"   // unread count prefix
    static func parseYouTubeTitle(_ raw: String) -> (title: String, artist: String) {
        var cleaned = raw
            .replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - YouTube", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Strip leading "(N) " unread counts YouTube adds to the tab title.
        if cleaned.hasPrefix("(") {
            if let closeParen = cleaned.firstIndex(of: ")") {
                let afterParen = cleaned.index(after: closeParen)
                if afterParen < cleaned.endIndex {
                    cleaned = String(cleaned[afterParen...])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
        }

        let parts = cleaned.components(separatedBy: " - ")
        if parts.count >= 2 {
            let title = parts[0].trimmingCharacters(in: .whitespaces)
            let artist = parts[1...].joined(separator: " - ")
                .trimmingCharacters(in: .whitespaces)
            return (title, artist)
        }
        return (cleaned, "")
    }

    static func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        // youtu.be/<id>
        if url.host == "youtu.be" {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    static func chromeSourceName(for url: String) -> String {
        if url.contains("music.youtube.com") { return "YouTube Music" }
        if url.contains("youtube.com") || url.contains("youtu.be") { return "YouTube" }
        if url.contains("soundcloud.com") { return "SoundCloud" }
        if url.contains("open.spotify.com") || url.contains("spotify.com") { return "Spotify Web" }
        if url.contains("music.163.com") { return "网易云音乐 (Web)" }
        if url.contains("y.qq.com") { return "QQ 音乐 (Web)" }
        if url.contains("bilibili.com") { return "哔哩哔哩" }
        return "Google Chrome"
    }

    // MARK: - JS

    private static func controlJavaScript(shouldPlay: Bool) -> String {
        if shouldPlay {
            return """
            (function() {
                var media = Array.from(document.querySelectorAll('video,audio'));
                if (!media.length) return 'NO_MEDIA';
                var target = media.find(function(item) { return item.paused && !item.ended; }) || media.find(function(item) { return !item.ended; }) || media[0];
                if (!target) return 'NO_MEDIA';
                try {
                    target.play();
                    return 'OK';
                } catch (error) {
                    return 'ERROR';
                }
            })();
            """
        }
        return """
        (function() {
            var media = Array.from(document.querySelectorAll('video,audio'));
            if (!media.length) return 'NO_MEDIA';
            var handled = false;
            media.forEach(function(item) {
                if (!item.paused && !item.ended) {
                    item.pause();
                    handled = true;
                }
            });
            return handled ? 'OK' : 'NO_MATCH';
        })();
        """
    }

    private static func escapeAppleScriptString(_ v: String) -> String {
        v.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
