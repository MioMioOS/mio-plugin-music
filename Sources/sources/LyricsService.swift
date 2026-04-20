//
//  LyricsService.swift
//  MioIsland Music Plugin
//
//  Fetches synced lyrics from LRCLIB (https://lrclib.net/docs) and parses
//  their LRC format into per-line timestamps. Free public API, no auth.
//
//  Approach borrowed from Atoll (github.com/Ebullioscopic/Atoll,
//  MusicManager.swift:756–895). Two lookup endpoints:
//
//    /api/get?track_name=…&artist_name=…&album_name=…&duration=…
//      — exact match with all four params; best hit rate when present.
//
//    /api/search?track_name=…&artist_name=…
//      — fallback text search, returns an array; we take the first.
//
//  LRC lines look like "[mm:ss.xx] Lyric line". We regex-extract the
//  timestamp + trailing text. Centiseconds optional.
//
//  Caching: in-memory LRU keyed by (artist + title + duration-bucket).
//  Bucket duration to nearest second so slight float drift between
//  MediaRemote and LRCLIB doesn't create separate cache keys. Cache
//  size capped at 32 entries — plenty for a single listening session.
//

import Foundation

// MARK: - Public types

struct LyricLine: Equatable, Identifiable {
    let id = UUID()
    let timestamp: TimeInterval
    let text: String
}

enum LyricsService {
    // MARK: - Cache

    /// Cache entry — an empty array means "we tried, nothing found".
    /// This negative-cache prevents hammering LRCLIB on songs with no
    /// lyrics (e.g. instrumentals).
    private struct CacheEntry {
        let lines: [LyricLine]
        let cachedAt: Date
    }

    private static let cacheQueue = DispatchQueue(
        label: "mio-plugin-music.lyrics-cache",
        attributes: .concurrent
    )
    private static var _cache: [String: CacheEntry] = [:]
    private static let maxCacheSize = 32
    private static let cacheTTL: TimeInterval = 60 * 60 // 1 hour

    private static func cacheKey(artist: String, title: String, duration: TimeInterval) -> String {
        let bucket = Int(duration.rounded())
        return "\(artist.lowercased())|\(title.lowercased())|\(bucket)"
    }

    private static func lookupCache(key: String) -> [LyricLine]? {
        var result: [LyricLine]?
        cacheQueue.sync {
            if let entry = _cache[key],
               Date().timeIntervalSince(entry.cachedAt) < cacheTTL {
                result = entry.lines
            }
        }
        return result
    }

    private static func storeCache(key: String, lines: [LyricLine]) {
        cacheQueue.async(flags: .barrier) {
            if _cache.count >= maxCacheSize {
                // Naive eviction: drop the oldest entry. Perfect LRU
                // isn't worth extra bookkeeping for N=32.
                if let oldestKey = _cache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
                    _cache.removeValue(forKey: oldestKey)
                }
            }
            _cache[key] = CacheEntry(lines: lines, cachedAt: Date())
        }
    }

    // MARK: - Fetch

    /// Fetch synced lyrics for the given track. Returns an empty array on
    /// "tried and no lyrics found" — the caller should treat nil (error)
    /// and [] (no lyrics) as distinct states for UX. Safe to call off the
    /// main actor; result is not main-isolated.
    static func fetch(
        artist: String,
        title: String,
        album: String = "",
        duration: TimeInterval = 0
    ) async -> [LyricLine] {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty, !trimmedTitle.isEmpty else { return [] }

        let key = cacheKey(artist: trimmedArtist, title: trimmedTitle, duration: duration)
        if let cached = lookupCache(key: key) { return cached }

        // 1. Exact match (best hit rate when album + duration are known).
        if duration > 0 {
            if let lines = try? await fetchExact(
                artist: trimmedArtist,
                title: trimmedTitle,
                album: album,
                duration: duration
            ) {
                storeCache(key: key, lines: lines)
                return lines
            }
        }

        // 2. Search fallback.
        if let lines = try? await fetchSearch(artist: trimmedArtist, title: trimmedTitle) {
            storeCache(key: key, lines: lines)
            return lines
        }

        storeCache(key: key, lines: [])
        return []
    }

    private static let baseURL = "https://lrclib.net/api"

    private struct GetResponse: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private struct SearchResultItem: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private static func fetchExact(
        artist: String,
        title: String,
        album: String,
        duration: TimeInterval
    ) async throws -> [LyricLine] {
        var comps = URLComponents(string: "\(baseURL)/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("mio-plugin-music/2.2 (+https://github.com/MioMioOS/mio-plugin-music)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        if let decoded = try? JSONDecoder().decode(GetResponse.self, from: data) {
            if let synced = decoded.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
               !synced.isEmpty {
                return parseLRC(synced)
            }
            if let plain = decoded.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
               !plain.isEmpty {
                return [LyricLine(timestamp: 0, text: plain)]
            }
        }
        return []
    }

    private static func fetchSearch(
        artist: String,
        title: String
    ) async throws -> [LyricLine] {
        var comps = URLComponents(string: "\(baseURL)/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("mio-plugin-music/2.2 (+https://github.com/MioMioOS/mio-plugin-music)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        if let items = try? JSONDecoder().decode([SearchResultItem].self, from: data),
           let first = items.first {
            if let synced = first.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
               !synced.isEmpty {
                return parseLRC(synced)
            }
            if let plain = first.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
               !plain.isEmpty {
                return [LyricLine(timestamp: 0, text: plain)]
            }
        }
        return []
    }

    // MARK: - LRC parsing

    /// LRC timestamp regex — matches [mm:ss] and [mm:ss.xx] (centiseconds
    /// optional). Captures three groups: minutes, seconds, centiseconds.
    private static let lrcRegex: NSRegularExpression = {
        // Force-try here: pattern is static and known-valid at compile time.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,2}))?\\]",
            options: []
        )
    }()

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = lrcRegex.firstMatch(in: raw, options: [], range: range) else {
                continue
            }
            let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let centi: Double = {
                let r = match.range(at: 3)
                return r.location != NSNotFound ? (Double(ns.substring(with: r)) ?? 0) : 0
            }()
            let ts = minutes * 60 + seconds + centi / 100.0

            let textStart = match.range.location + match.range.length
            guard textStart <= ns.length else { continue }
            let text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            out.append(LyricLine(timestamp: ts, text: text))
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }
}
