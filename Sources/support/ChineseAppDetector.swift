//
//  ChineseAppDetector.swift
//  MioIsland Music Plugin
//
//  Detects whether a Chinese desktop music app (QQ 音乐 / 网易云音乐 / 酷狗)
//  is currently running. These apps do not publish their Now Playing state
//  to MediaRemote and do not expose a scripting dictionary, so we cannot
//  read tracks from them. When detected, the UI surfaces a polite message
//  telling the user to switch to the web player instead of showing an empty
//  or misleading Now Playing view.
//

import AppKit

struct ChineseAppDetector {
    private struct Rule {
        let bundleIDs: [String]
        let nameFragments: [String]
        let displayName: String
    }

    // Bundle IDs are the primary key; localized name fragments are a fallback
    // in case the vendor ships a repackaged build with a different bundle ID.
    private static let rules: [Rule] = [
        Rule(
            bundleIDs: ["com.tencent.qqmusicmac", "com.tencent.QQMusicMac"],
            nameFragments: ["QQ音乐", "QQ 音乐", "QQMusic"],
            displayName: "QQ 音乐"
        ),
        Rule(
            bundleIDs: ["com.netease.163music", "com.netease.cloudmusicmac"],
            nameFragments: ["网易云音乐", "网易云", "NeteaseMusic", "CloudMusic"],
            displayName: "网易云音乐"
        ),
        Rule(
            bundleIDs: ["com.kugou.mac", "com.kugou.KuGouMusic"],
            nameFragments: ["酷狗", "KuGou"],
            displayName: "酷狗音乐"
        )
    ]

    /// Return the display name of the first matching running app, or nil.
    static func detectRunning() -> String? {
        let apps = NSWorkspace.shared.runningApplications
        for rule in rules {
            for app in apps {
                if app.isTerminated { continue }

                if let bid = app.bundleIdentifier,
                   rule.bundleIDs.contains(where: { bid.caseInsensitiveCompare($0) == .orderedSame }) {
                    return rule.displayName
                }

                if let name = app.localizedName {
                    for frag in rule.nameFragments
                    where name.range(of: frag, options: .caseInsensitive) != nil {
                        return rule.displayName
                    }
                }
            }
        }
        return nil
    }
}
