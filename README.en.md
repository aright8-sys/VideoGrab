<p align="center">
  <img src="Assets/AppIcon.png" width="128" height="128" alt="VideoGrab logo">
</p>

<h1 align="center">VideoGrab</h1>

<p align="center">
  A lightweight macOS menu bar app: <strong>paste a link, download videos from Bilibili, Xinpianchang, Xiaohongshu (RED), and YouTube</strong>.
</p>

<p align="center">
  <a href="README.md">中文</a> ·
  <strong>English</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?logo=apple" alt="platform">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift&logoColor=white" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>

<p align="center">
  <img src="docs/screenshot.png" width="380" alt="VideoGrab screenshot">
</p>

It lives in your menu bar. Open the panel, paste (or auto-detect from clipboard) a video URL, pick a quality, and save locally. Ships with yt-dlp + ffmpeg and handles per-site network routing automatically.

- 🪶 **Lightweight** — native Swift + SwiftUI, no third-party dependencies
- 🔗 **Multi-site** — Bilibili, Xinpianchang, Xiaohongshu (RED), YouTube (incl. short links `b23.tv` / `xhslink.com` / `youtu.be`)
- 🌐 **Smart routing** — CN sites connect directly; overseas sites auto-detect local Clash proxy ports
- 🍪 **Login cookies** — Bilibili / Xiaohongshu read Chrome cookies automatically, no manual export
- 📋 **Clipboard prefill** — detects video URLs from clipboard when the panel opens
- 📊 **Progress & notify** — live progress bar; system notification on completion; click to open save folder

> 📦 **Download**: grab the prebuilt `VideoGrab.zip` from [Releases](https://github.com/aright8-sys/VideoGrab/releases/latest), or build it yourself (see below).

## 🆕 Changelog

### v2.0 — Redesigned UI + Xiaohongshu support

A major release with a fully reworked interface and experience:

- 🌹 **Xiaohongshu (RED) downloads** — supports `xiaohongshu.com` / `xhslink.com` short links; direct CN connection + automatic Chrome login cookies.
- 🎨 **Completely redesigned UI** — card-based layout on a frosted-glass background, a blue→indigo brand gradient echoing the app icon, and subtle top highlight strokes on every card.
- 🖼️ **New app icon** — reshaped to Apple's latest spec (transparent margins, standard squircle corners) instead of a hard square.
- 🎚️ **Icon-based quality picker** — Best / 1080p / 720p / Audio as four clear pill buttons with a highlighted selection.
- 📊 **Prettier download flow** — custom gradient progress bar + large animated percentage, smooth state transitions; success / failure shown as green / orange cards with one-click "open in Finder".
- ❓ **"Update core" help** — a clickable question mark next to it pops up an explanation of what the yt-dlp "core" is.
- ✨ **Enhanced input field** — inline clear button, link icon, one-tap paste.

## ⚠️ Disclaimer

> This is a personal project, **not affiliated with, authorized, or endorsed by Bilibili,
> Xinpianchang, YouTube, or Google**.
> It downloads videos via [yt-dlp](https://github.com/yt-dlp/yt-dlp), which may violate each
> platform's Terms of Service; downloading copyrighted content may carry legal risk.
>
> **Where your data goes**:
> - **Downloads**: yt-dlp runs locally; files are saved to a folder you choose.
> - **Login cookies**: read from your local Chrome browser only when downloading Bilibili / Xiaohongshu;
>   never uploaded or sent elsewhere.
> - **Core updates**: "Update core" fetches the latest yt-dlp from GitHub (overseas; uses local proxy).
>
> For personal, educational use only — **use at your own risk and respect platform ToS and copyright law**.

## How it works

### Network routing

Different sites need opposite network paths; the app picks automatically by hostname:

| Site | Route |
| --- | --- |
| Xinpianchang | Direct |
| Bilibili | Direct + Chrome cookies |
| Xiaohongshu (RED) | Direct + Chrome cookies |
| YouTube | Local Clash proxy (7897/7890, etc.) |

On launch, inherited `*_proxy` environment variables are cleared so GUI and terminal behave consistently.

### Download core

`build-app.sh` downloads yt-dlp and ffmpeg into `Resources/bin/` and bundles them into `.app`.
On first run they are copied to `~/Library/Application Support/VideoGrab/bin/` (writable, self-updatable).

### What is "Update core"?

The "Update core" button at the bottom of the panel upgrades the **yt-dlp** download engine. VideoGrab itself is only the GUI shell — yt-dlp (with ffmpeg) does the actual page parsing, stream fetching, and muxing, hence the "core". Video sites change their pages and anti-bot measures often, which can break an older yt-dlp. **When a link suddenly fails to download, click "Update core" first**: it runs `yt-dlp -U`, self-updates the writable copy in Application Support (no reinstall needed), uses your local proxy or a direct connection automatically, and shows the new version when done.

## Build & run

Requires macOS 14+ and a Swift toolchain (Xcode or the Command Line Tools is enough — you don't need to
open Xcode).

```bash
./build-app.sh            # compile and package into VideoGrab.app
open VideoGrab.app        # run
cp -r VideoGrab.app /Applications/   # install (optional)
```

Development:

```bash
swift build               # compile only
```

## Usage

1. After launching, click the ⬇️ icon in the menu bar.
2. Copy a video URL; open the panel (clipboard URL is auto-filled).
3. Pick a quality and click "Download".
4. **Bilibili / Xiaohongshu first time**: if a "Chrome Safe Storage" Keychain prompt appears, click
   "Always Allow" and enter your password (once only). For login-gated content, sign in to the site in
   Chrome first.
5. **YouTube**: start your local Clash (or similar) proxy first.

## Project layout

```
Sources/VideoGrab/
  VideoGrabApp.swift   App entry + MenuBarExtra
  AppState.swift       State, clipboard prefill, download scheduling
  Downloader.swift     yt-dlp wrapper, proxy routing, progress parsing
  Sites.swift          Supported site hostnames
  PopoverView.swift    Popover panel UI
  Notify.swift         Download-complete notifications
build-app.sh           Packaging script (fetch cores + write LSUIElement)
```

## License

[MIT](LICENSE)
