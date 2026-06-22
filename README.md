<p align="center">
  <img src="Assets/AppIcon.png" width="128" height="128" alt="VideoGrab logo">
</p>

<h1 align="center">VideoGrab</h1>

<p align="center">
  一个轻量的 macOS 菜单栏小工具：<strong>粘贴链接，一键下载 B站、新片场、YouTube 视频</strong>。
</p>

<p align="center">
  <strong>中文</strong> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?logo=apple" alt="platform">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift&logoColor=white" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

<p align="center">
  <img src="docs/screenshot.png" width="380" alt="VideoGrab 截图">
</p>

它常驻菜单栏，打开面板后粘贴（或自动识别剪贴板里的）视频链接，选择画质，即可下载到本地。内置 yt-dlp + ffmpeg，自动处理国内/国外站点的网络分流。

- 🪶 **轻巧**：原生 Swift + SwiftUI，无第三方依赖
- 🔗 **多站点**：B站、新片场、YouTube（含短链 `b23.tv` / `youtu.be`）
- 🌐 **智能分流**：国内站强制直连，国外站自动探测本地 Clash 代理端口
- 🍪 **B站登录态**：自动读取 Chrome Cookie，无需手动导出
- 📋 **剪贴板预填**：打开面板时自动识别剪贴板中的视频链接
- 📊 **进度与通知**：实时进度条，完成后系统通知，点击打开保存目录

> 📦 **直接下载**：前往 [Releases](https://github.com/aright8-sys/VideoGrab/releases/latest) 下载打包好的 `VideoGrab.zip`，或按下方说明自行构建。

## ⚠️ 免责声明

> 本项目为个人作品，**与 Bilibili、新片场、YouTube / Google 均无关，未获其授权或背书**。
> 它通过 [yt-dlp](https://github.com/yt-dlp/yt-dlp) 下载视频，可能违反各平台服务条款；
> 下载受版权保护的内容可能涉及法律风险。
>
> **数据流向**：
> - **下载过程**：在本机调用 yt-dlp，视频文件保存到你指定的本地目录。
> - **B站 Cookie**：仅在下载 B站时，从本机 Chrome 浏览器读取登录 Cookie，不上传、不外发。
> - **内核更新**：「更新内核」会从 GitHub 拉取最新 yt-dlp（国外站点，走本地代理）。
>
> 仅供个人学习与自用，**请自行评估并承担使用风险，遵守平台条款与版权法**。

## 工作原理

### 网络分流

不同站点对代理的需求相反，App 会按目标域名自动选择：

| 站点 | 走法 |
| --- | --- |
| 新片场 | 直连 |
| B站 | 直连 + Chrome Cookie |
| YouTube | 走本地 Clash 代理（7897/7890 等） |

App 启动时会清理继承来的 `*_proxy` 环境变量，避免 GUI 与终端行为不一致。

### 下载内核

首次构建时 `build-app.sh` 会下载 yt-dlp 和 ffmpeg 到 `Resources/bin/`，打包进 `.app`。
首次运行时复制到 `~/Library/Application Support/VideoGrab/bin/`（可写、可自更新）。

## 构建与运行

需要 macOS 14+ 和 Swift 工具链（Xcode 或 Command Line Tools 即可，无需打开 Xcode）。

```bash
./build-app.sh            # 编译并打包成 VideoGrab.app
open VideoGrab.app        # 运行
cp -r VideoGrab.app /Applications/   # 安装（可选）
```

开发调试：

```bash
swift build               # 仅编译
```

## 使用

1. 启动后点击菜单栏的 ⬇️ 图标。
2. 复制视频链接，打开面板（会自动填入剪贴板中的链接）。
3. 选择画质，点击「下载」。
4. **B站首次使用**：若弹出「Chrome Safe Storage」钥匙串窗口，点「始终允许」+ 输入开机密码（只需一次）。
5. **YouTube**：需先启动本地 Clash 等代理。

## 目录结构

```
Sources/VideoGrab/
  VideoGrabApp.swift   App 入口 + MenuBarExtra
  AppState.swift       状态管理、剪贴板预填、下载调度
  Downloader.swift     yt-dlp 封装、代理分流、进度解析
  Sites.swift          受支持站点域名
  PopoverView.swift    弹出面板 UI
  Notify.swift         下载完成系统通知
build-app.sh           打包脚本（下载内核 + 写入 LSUIElement）
```

## 许可证

[MIT](LICENSE)
