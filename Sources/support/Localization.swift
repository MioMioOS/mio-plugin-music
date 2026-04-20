//
//  Localization.swift
//  MusicPlugin
//
//  Minimal zh/en string map for the Now Playing plugin. Follows the
//  same pattern as StatsPlugin: the host app's `appLanguage`
//  UserDefault is the single source of truth, with an "auto" fallback
//  to system locale.
//

import Foundation

enum L10n {
    /// "zh" when the user has selected Chinese (explicitly or via system
    /// locale fallback), "en" otherwise. Two discrete cases, no third.
    static var language: String {
        isChinese ? "zh" : "en"
    }

    static var isChinese: Bool {
        let setting = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        switch setting {
        case "zh": return true
        case "en": return false
        default:
            if let code = Locale.current.language.languageCode?.identifier,
               code.hasPrefix("zh") {
                return true
            }
            if let pref = Locale.preferredLanguages.first,
               pref.hasPrefix("zh") {
                return true
            }
            return false
        }
    }

    // MARK: - Empty state

    static var nothingPlaying: String {
        isChinese ? "暂无播放" : "Nothing playing"
    }

    static var nothingPlayingHint: String {
        isChinese
            ? "在 Spotify、Apple Music 或 Chrome 里播放音乐"
            : "Play something in Spotify, Apple Music, or Chrome"
    }

    // MARK: - Host version too old

    static var hostUpgradeTitle: String {
        isChinese ? "需要 Mio Island v2.1.7+" : "Mio Island v2.1.7+ required"
    }

    static var hostUpgradeHint: String {
        isChinese
            ? "请升级主 app 以启用完整功能"
            : "Please upgrade Mio Island to unlock full plugin features"
    }

    // MARK: - Chinese app running detection

    static func chineseAppTitle(_ appName: String) -> String {
        isChinese ? "检测到 \(appName) 运行" : "\(appName) detected"
    }

    static var chineseAppHint: String {
        isChinese
            ? "桌面端暂不支持曲目抓取，试试打开网页版"
            : "Desktop version not supported. Try the web version in Chrome."
    }

    // MARK: - Small bits used around the card

    /// Separator glyph placed between artist and album in compact layouts.
    static var byArtist: String {
        isChinese ? "・" : "by"
    }

    /// Short label used near the playback source badge.
    static var sourceLabel: String {
        isChinese ? "来源" : "Source"
    }

    /// "Now Playing" heading for the expanded card.
    static var nowPlayingHeading: String {
        isChinese ? "正在播放" : "Now Playing"
    }

    /// Accessibility / tooltip labels for transport controls.
    static var playTooltip: String {
        isChinese ? "播放" : "Play"
    }

    static var pauseTooltip: String {
        isChinese ? "暂停" : "Pause"
    }

    static var previousTooltip: String {
        isChinese ? "上一首" : "Previous"
    }

    static var nextTooltip: String {
        isChinese ? "下一首" : "Next"
    }

    /// Fallback strings shown when NowPlayingState has a blank field but
    /// we still need to render something (e.g. while the first Chrome
    /// query is in flight).
    static var unknownTitle: String {
        isChinese ? "未知曲目" : "Unknown Title"
    }

    static var unknownArtist: String {
        isChinese ? "未知艺术家" : "Unknown Artist"
    }

    static var floatLyricsTooltip: String {
        isChinese ? "悬浮歌词窗 · 点击切换显示" : "Floating lyrics window · toggle visibility"
    }

    static var lyricsPlaceholder: String {
        isChinese ? "歌词暂未接入 · 等待真实数据源" : "Lyrics not wired yet — placeholder"
    }

    static var lyricsStyleLabel: String {
        isChinese ? "样式" : "Style"
    }
}
