//
//  HostVersionCheck.swift
//  MioIsland Music Plugin
//
//  Determines whether the host app (Mio Island) is new enough to provide
//  NSAppleEventsUsageDescription, which is required for any AppleScript
//  based source (Spotify / Music / Chrome). If the host is too old, the UI
//  surfaces an "upgrade to Mio Island X.Y.Z" banner instead of silently
//  showing no track.
//
//  We intentionally avoid any dependency on third party version libraries.
//  Semantic version comparison is implemented manually via tuple compare.
//

import Foundation

struct HostVersionCheck {
    /// Minimum host version that ships NSAppleEventsUsageDescription.
    static let minRequired = "2.1.7"

    /// Known Mio Island bundle IDs. Accept all of them so dev / staging /
    /// white-labelled builds still report as "on host" correctly.
    /// Real host bundle ID is historical ("Code Island" -> renamed "Mio Island"
    /// at display layer only; bundle ID kept stable for Sparkle update continuity).
    private static let hostBundleIDs: Set<String> = [
        "com.codeisland.app",
        "com.mioisland.app",
        "com.mioisland.ClaudeIsland",
        "com.mio.island",
        "chat.miomio.island"
    ]

    /// Read CFBundleShortVersionString from the hosting process. Returns nil
    /// if Bundle.main has no version key (should not happen in practice).
    static func hostVersion() -> String? {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !v.isEmpty {
            return v
        }
        return nil
    }

    /// True when the current host process is Mio Island, per bundle ID.
    static func isMioIslandHost() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return false }
        if hostBundleIDs.contains(bid) { return true }
        // Loose match for renamed development builds or white-labelled forks.
        return bid.localizedCaseInsensitiveContains("mioisland") ||
            bid.localizedCaseInsensitiveContains("mio.island") ||
            bid.localizedCaseInsensitiveContains("codeisland")
    }

    /// True when host version is ≥ minRequired. Non Mio Island processes
    /// (e.g. the compile-only linter) pass through as true so we do not
    /// accidentally block in unrelated hosts.
    static func isOK() -> Bool {
        guard isMioIslandHost() else { return true }
        guard let version = hostVersion() else { return false }
        return compare(version, minRequired) != .orderedAscending
    }

    // MARK: - Semantic version compare (handwritten, no third party lib)

    /// Compare two dot-separated numeric version strings. Non-numeric or
    /// missing components default to 0. Examples:
    ///   compare("2.1.7",  "2.1.7")  -> .orderedSame
    ///   compare("2.1.6",  "2.1.7")  -> .orderedAscending
    ///   compare("2.2.0",  "2.1.7")  -> .orderedDescending
    ///   compare("2.1.7.1","2.1.7")  -> .orderedDescending
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = components(of: lhs)
        let r = components(of: rhs)
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(of version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { part -> Int in
                // Strip any non-digit suffix e.g. "7-beta" -> 7.
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
