<p align="center">
  <img src="Assets/AppIcon.png" width="128" height="128" alt="VideoGrab logo">
</p>

<h1 align="center">VideoGrab</h1>

<p align="center">
  A lightweight macOS menu bar app: <strong>copy a video link, open the panel, save it locally</strong>.
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

It lives in your menu bar. Copy a video URL, open the panel (it auto-fills), pick a quality, and save locally. Ships with yt-dlp + ffmpeg and handles per-site network routing automatically.

- 🪶 **Lightweight** — native Swift + SwiftUI, no third-party dependencies
- 🔗 **Common video sites** — built-in engine, plus dedicated parsers where needed. WeChat Channels is recognized but not downloadable
- 🌐 **Smart routing** — CN sites connect directly; overseas sites auto-detect local Clash proxy ports
- 🍪 **Login cookies** — sites that need a login read Chrome cookies automatically
- 📋 **Clipboard auto-collect** — a persistent clipboard watcher adds every video URL you copy in the browser straight to the download list (toggle it off in the panel); pasting a whole block of links works too, duplicates are ignored
- 📚 **Batch download queue** — multiple links download one by one with "n of N" progress; a single failure doesn't break the queue, and you get exactly one notification at the end
- 📊 **Progress & notify** — live progress bar; system notification on completion; click to open save folder
- 🔍 **Check for updates** — one click queries GitHub Releases; you can install and relaunch from the panel, or open the web download page

> 📦 **Download**: grab the prebuilt `VideoGrab.zip` from [Releases](https://github.com/aright8-sys/VideoGrab/releases/latest), or build it yourself (see below).

## 🆕 Changelog

### v2.5 — Vimeo removed & proxy detection fix

- 🛡️ **Proxy detection fixed (ATS)** — the app does not relax App Transport Security, so the cleartext-HTTP proxy probe was rejected and every foreign site (Pinterest / YouTube / …) complained "needs a local proxy". The probe now uses HTTPS and detection works again.
- 🗑️ **Vimeo downloads removed** — Vimeo videos are now DRM-encrypted (CENC adaptive streams, no clear direct source), so they can no longer be downloaded; the Vimeo downloader and headless-Chrome dependency were removed, and Vimeo links now say "not supported" clearly.

### v2.4 — In-app one-tap update

- ⬇️ **Install from the panel** — after "Check for updates", a new version can be downloaded, verified, and swapped in place, then the app relaunches; **Web download** remains available.
- 🔒 **Verified packages** — only this repo's tagged `VideoGrab.zip` is accepted, checked against GitHub's sha256 digest; the bundle ID must match and the version must be strictly newer. Downloads can be cancelled; a failed install rolls back.
- 📋 **Clipboard watch is optional** — turn it off from the link-list toolbar; the choice is remembered. New URLs are not ingested while a download or app update is running.

### v2.3 — Batch queue & clipboard auto-collect

- 📚 **Batch download queue** — paste multiple links at once and they download sequentially. The progress card shows "item n of N"; one failed link doesn't stop the queue. You get a single system notification at the end ("queue finished" or "X succeeded, Y failed"), and the result card lists failed links, copyable.
- 📋 **Clipboard auto-collect** — the app watches the clipboard in the background: every URL you copy in the browser lands in the download list automatically, no need to open the panel or paste manually. Copying a whole block of links from a text file works as well (one per line or inline). Duplicate copies count once.
- 🔢 **List-style link input** — each link is its own row with a numbered badge and a hairline divider, with a live counter in the footer strip. Rows are editable inline; pasting a multi-line block into a row splits it automatically. When the list grows past the available screen height it folds into a scroll area (height adapts to your screen) while the counter strip stays visible.
- 🔍 **Check for updates** — a new "Check for updates" button in the bottom-right queries GitHub Releases; a new version pops a banner that opens the download page, otherwise you get a brief "already latest" note.
- 🧹 **Single-link behavior unchanged** — with one link everything works exactly as before, including the single "download complete" notification.


### v2.2 — Vimeo downloads & hardening
- 🎬 **Vimeo downloads** — the usual extractor is blocked; VideoGrab uses local Chrome to pass the challenge and reassembles DASH segments (Google Chrome must be installed).
- ⚡ **Faster, leaner Vimeo** — segments fetch four at a time and stream to disk (long videos no longer sit entirely in memory); the title is taken as soon as it's ready, and Cloudflare challenge titles ("Just a moment…") never become the filename.
- 📌 **Pinterest** — native pins still go through yt-dlp; embedded Vimeo pins are handed to the Vimeo parser.
- 💬 **WeChat Channels** — recognized, then told clearly that download isn't supported (no public download API).
- 🛡️ **Proxy detection false positives fixed** — after finding an open local port, VideoGrab sends one real request through it to confirm it actually is a proxy; random apps squatting on 8080/8888 are no longer mistaken for Clash (which used to break all foreign-site downloads).
- 🔒 **Stricter site & URL matching** — hosts now match by domain suffix, so spoofed domains like `bilibili.com.evil.com` are no longer treated as Bilibili and forced direct; clipboard links only accept legal URL characters — links glued to Chinese text (no space) previously swallowed the entire sentence into the URL and failed, now they're cut at the first illegal character.
- 🔄 **ffmpeg follows app updates** — the writable copy carries a version fingerprint and is refreshed automatically when a newer build ships, instead of staying frozen at the first-installed version forever; yt-dlp still self-updates via "Update core" and is never overwritten.
- 🧵 **Two rare race conditions fixed** — the notification's target folder is lock-guarded against concurrent read/write, and stale callbacks from a cancelled download are invalidated by generation, so instantly starting a new download can't have its progress polluted by the dying one.
- 📦 **Reproducible builds** — `build-app.sh` pins yt-dlp / ffmpeg versions and verifies sha256 digests; truncated or tampered kernels abort the build, and mismatched existing ones are re-fetched automatically.
- ✅ **Automated tests added** — 13 tests pin down every site parser (domain matching / URL trimming / progress parsing / Xinpianchang quality picking / WeChat short IDs / Pinterest→Vimeo detection / Vimeo manifest parsing); run `swift test` once to know if a change broke something.

### v2.1 — Fix Xinpianchang downloads

- 🔧 **Fixed broken Xinpianchang downloads**: article pages now sit behind a Wangsu JS anti-bot challenge, so yt-dlp's direct page fetch gets `403 / 406`. VideoGrab now resolves the direct link via the mobile share API (which bypasses the challenge) and downloads it with a native downloader — the CDN requires a `Range` header and the link is an IP-bound pre-signed URL that can't be routed through yt-dlp.
- 🧾 **Scrollable error card**: long errors are no longer truncated or hidden behind the footer; fully selectable and copyable.

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
> - **Login cookies**: read from your local Chrome browser only when a site needs a login session;
>   never uploaded or sent elsewhere.
> - **Core updates**: "Update core" fetches the latest yt-dlp from GitHub (overseas; uses local proxy).
> - **Update check**: queries the GitHub API for the latest version number; choosing one-tap install downloads the zip from GitHub and replaces the app locally. Read-only; nothing is uploaded.
>
> For personal, educational use only — **use at your own risk and respect platform ToS and copyright law**.

## How it works

### Network routing

Different sites need opposite network paths; the app picks automatically by hostname:

| Kind | Route |
| --- | --- |
| CN sites | Direct |
| Login-gated sites | Chrome cookies |
| Overseas sites | Local Clash proxy (7897/7890, etc.) |
| Vimeo | Not supported now (removed; video is DRM-protected) |
| WeChat Channels | Title lookup only; no download |

On launch, inherited `*_proxy` environment variables are cleared so GUI and terminal behave consistently.

### Download core

`build-app.sh` downloads yt-dlp and ffmpeg into `Resources/bin/` and bundles them into `.app`.
On first run they are copied to `~/Library/Application Support/VideoGrab/bin/` (writable, self-updatable).

### What is "Update core"?

The "Update core" button at the bottom of the panel upgrades the **yt-dlp** download engine. VideoGrab itself is only the GUI shell — yt-dlp (with ffmpeg) does the actual page parsing, stream fetching, and muxing, hence the "core". Video sites change their pages and anti-bot measures often, which can break an older yt-dlp. **When a link suddenly fails to download, click "Update core" first**: it runs `yt-dlp -U`, self-updates the writable copy in Application Support (no reinstall needed), uses your local proxy or a direct connection automatically, and shows the new version when done.

### What is "Check for updates"?

The "Check for updates" button in the bottom-right upgrades VideoGrab itself. It queries GitHub Releases for the latest version and compares it with the local one:

- **New version available**: a banner appears. If the Release includes `VideoGrab.zip` and a sha256 digest, tap **Update now** to download, verify, replace, and relaunch; **Web download** still opens the Release page.
- **Already up to date**: a brief note with the current version.
- The query goes to the GitHub API (overseas; uses your local proxy or a direct connection automatically). The anonymous API allows 60 requests/hour — plenty for manual checks.
- Auto-update only accepts this repo's tagged GitHub asset URLs and checks SHA-256 against GitHub's digest. There is no Developer ID, so quarantine is cleared and the bundle is ad-hoc signed only after that verification, so the new instance can launch.


## Build & run

Requires macOS 14+ and a Swift toolchain (Xcode or the Command Line Tools is enough — you don't need to
open Xcode).

```bash
./build-app.sh            # compile and package into VideoGrab.app
open VideoGrab.app        # run
cp -r VideoGrab.app /Applications/   # install (optional)
```

```bash
swift build               # compile only
swift test                # parser tests
```

## Usage

1. After launching, click the ⬇️ icon in the menu bar.
2. Copy a video URL — one or many; copying a whole block from a text file works too. Links are collected into the panel's list automatically, no manual pasting needed.
3. Pick a quality and click "Download". With multiple links the button shows the count and downloads them as a queue, notifying you once at the end.
4. **Login-gated content**: if a "Chrome Safe Storage" Keychain prompt appears, click
   "Always Allow" and enter your password (once only). Sign in to the site in Chrome first.
5. **YouTube and other overseas sites**: start your local Clash (or similar) proxy first.
6. **Vimeo**: not supported now (video is DRM-protected; the dedicated downloader was removed).
7. **WeChat Channels**: download is not supported.
8. **Check for updates**: use the "Check for updates" button in the bottom-right; a new version can be installed in one tap. Clipboard auto-collect can be turned off from the link-list toolbar.

## Project layout

```
Sources/VideoGrab/
  VideoGrabApp.swift       App entry + MenuBarExtra
  AppState.swift           State, clipboard auto-collect, batch queue scheduling
  Downloader.swift         yt-dlp wrapper, proxy routing, progress parsing
  Sites.swift              Site matching and URL trimming
  PopoverView.swift        Popover panel UI
  Notify.swift             Download-complete notifications
  UpdateChecker.swift      GitHub Releases update check
  SelfUpdater.swift        Download zip, verify hash, replace and relaunch
  PinterestResolver.swift  Pinterest native / embedded-video detection
  WechatChannels.swift     Channels lookup (no download)
  Xinpianchang.swift       Xinpianchang direct-link parser
build-app.sh               Packaging script (fetch cores + write LSUIElement)
```

## License

[MIT](LICENSE)
