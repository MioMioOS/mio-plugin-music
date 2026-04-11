# MioIsland 音乐播放器插件

一款原生插件，将实时音乐播放信息带到你的 MioIsland Notch 栏。无需离开工作流，即可查看 Mac 上正在播放的音乐。

## 功能特性

- 显示当前播放的曲目、艺术家和专辑，支持任何 macOS 音乐应用（Apple Music、Spotify 等）
- 读取系统 NowPlaying 元数据，无需单独配置各个应用
- 轻量级原生 `.bundle` 插件，资源占用极低
- 流畅的动画界面，与 MioIsland 设计语言一致
- 以头部图标按钮的形式显示在 Notch 栏中

## 截图

*即将添加*

## 安装方式

### 从 MioIsland 插件商店安装

1. 访问 [miomio.chat](https://miomio.chat)
2. 找到「音乐播放器」并点击安装
3. MioIsland 会自动下载并激活插件

### 手动安装

```bash
cp -r music-player.bundle ~/.config/codeisland/plugins/
```

重启 MioIsland 即可加载插件。

## 从源码编译

环境要求：
- macOS 15.0+
- Xcode 命令行工具
- Swift 5.9+

```bash
git clone https://github.com/xmqywx/mio-plugin-music.git
cd mio-plugin-music
bash build.sh
```

编译脚本会输出：
- `build/music-player.bundle` — 插件文件（复制到 `~/.config/codeisland/plugins/`）
- `build/music-player.zip` — 压缩包，用于上传到插件商店

## 插件架构

| 文件 | 用途 |
|------|------|
| `MioPlugin.swift` | 插件协议定义 |
| `MusicPlugin.swift` | 插件主入口 — 激活、停用、创建视图 |
| `MusicPlayerView.swift` | SwiftUI 视图，显示曲目信息 |
| `MusicHeaderButton.swift` | Notch 栏的头部图标按钮 |
| `NowPlayingBridge.swift` | 桥接 macOS NowPlaying 系统 API |

## 工作原理

插件使用 macOS `MRMediaRemoteGetNowPlayingInfo` API 读取系统级的 NowPlaying 信息。这适用于任何向系统报告播放状态的应用，包括：

- Apple Music
- Spotify
- YouTube（浏览器中）
- VLC
- 任何使用 MPNowPlayingInfoCenter 的应用

## 许可证

MIT

## 作者

[@xmqywx](https://github.com/xmqywx)
