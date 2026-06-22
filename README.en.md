<h1 align="center">VideoGrab</h1>

<p align="center">
  A lightweight macOS menu bar app: <strong>paste a link, download videos from Bilibili, Xinpianchang, and YouTube</strong>.
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

It lives in your menu bar. Open the panel, paste (or auto-detect from clipboard) a video URL, pick a quality, and save locally. Ships with yt-dlp + ffmpeg and handles per-site network routing automatically.

- 🪶 **Lightweight** — native Swift + SwiftUI, no third-party dependencies
- 🔗 **Multi-site** — Bilibili, Xinpianchang, YouTube (incl. short links `b23.tv` / `youtu.be`)
- 🌐 **Smart routing** — CN sites connect directly; overseas sites auto-detect local Clash proxy ports
- 🍪 **Bilibili auth** — reads Chrome cookies automatically, no manual export
- 📋 **Clipboard prefill** — detects video URLs from clipboard when the panel opens
- 📊 **Progress & notify** — live progress bar; system notification on completion; click to open save folder

> 📦 **Build yourself**: clone the repo and run `./build-app.sh` to produce `VideoGrab.app`.

## ⚠️ Disclaimer

> This is a personal project, **not affiliated with, authorized, or endorsed by Bilibili,
> Xinpianchang, YouTube, or Google**.
> It downloads videos via [yt-dlp](https://github.com/yt-dlp/yt-dlp), which may violate each
> platform's Terms of Service; downloading copyrighted content may carry legal risk.
>
> **Where your data goes**:
> - **Downloads**: yt-dlp runs locally; files are saved to a folder you choose.
> - **Bilibili cookies**: read from your local Chrome browser only when downloading Bilibili;
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
| YouTube | Local Clash proxy (7897/7890, etc.) |

On launch, inherited `*_proxy` environment variables are cleared so GUI and terminal behave consistently.

### Download core

`build-app.sh` downloads yt-dlp and ffmpeg into `Resources/bin/` and bundles them into `.app`.
On first run they are copied to `~/Library/Application Support/VideoGrab/bin/` (writable, self-updatable).

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
4. **Bilibili first time**: if a "Chrome Safe Storage" Keychain prompt appears, click "Always Allow"
   and enter your password (once only).
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
