import SwiftUI
import AppKit

struct LinkLine: Identifiable, Equatable {
    let id: UUID
    var text: String
    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var linkLines: [LinkLine] = []
    var urlText: String { linkLines.map(\.text).joined(separator: "\n") }

    @Published var quality: Quality = .best
    @Published var saveDir: URL

    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var statusLine: String = ""
    @Published var lastError: String = ""
    @Published var lastFinishedName: String = ""

    @Published var updatingCore = false
    @Published var coreVersion: String = ""

    @Published var checkingUpdate = false
    @Published var updateMessage = ""
    @Published var updateIsError = false
    @Published var updateFlow: UpdateFlow = .idle
    private var pendingRelease: UpdateChecker.Release?

    private let clipWatchKey = "VideoGrab.clipboardWatch"
    @Published var clipboardWatchEnabled: Bool

    private let downloader = Downloader()
    private let saveDirKey = "VideoGrab.saveDir"
    private var downloadID = 0

    @Published var queueTotal = 0
    @Published var queueIndex = 0
    @Published var queueSummary: QueueSummary?
    private var queueLinks: [String] = []
    private var queueSucceeded = 0
    private var queueFailures: [(link: String, message: String)] = []
    private var clearUpdateMsgTask: Task<Void, Never>?

    private var autoAddedURLs: Set<String> = []
    private var clipChangeCount = -1
    private var clipTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: saveDirKey) {
            saveDir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        clipboardWatchEnabled = defaults.object(forKey: clipWatchKey) as? Bool ?? true
        readCoreVersion()
        Notify.bootstrap()
        SelfUpdater.cleanupOldBundles()
        downloader.prewarmCookieAccess()
        if clipboardWatchEnabled { startClipboardWatch() }
    }

    var isUpdatingApp: Bool {
        switch updateFlow {
        case .downloading, .installing: return true
        default: return false
        }
    }

    deinit { clipTimer?.invalidate() }

    // MARK: - 链接列表

    var urlBinding: Binding<String> {
        Binding(get: { self.urlText }, set: { self.replaceURLText($0) })
    }

    func replaceURLText(_ text: String) {
        let rows = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var next: [LinkLine] = []
        for (i, row) in rows.enumerated() {
            if i < linkLines.count, linkLines[i].text == row {
                next.append(linkLines[i])
            } else if i < linkLines.count {
                next.append(LinkLine(id: linkLines[i].id, text: row))
            } else {
                next.append(LinkLine(text: row))
            }
        }
        linkLines = next
    }

    func clearLinks() { linkLines = [] }

    func lineBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.linkLines.first(where: { $0.id == id })?.text ?? "" },
            set: { self.updateLine(id: id, to: $0) }
        )
    }

    func updateLine(id: UUID, to newValue: String) {
        guard let idx = linkLines.firstIndex(where: { $0.id == id }) else { return }
        let pieces = newValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if pieces.isEmpty {
            linkLines.remove(at: idx)
            return
        }
        linkLines[idx].text = pieces[0]
        if pieces.count > 1 {
            let extras = pieces.dropFirst().map { LinkLine(text: $0) }
            linkLines.insert(contentsOf: extras, at: idx + 1)
        }
    }

    func setClipboardWatch(_ on: Bool) {
        clipboardWatchEnabled = on
        UserDefaults.standard.set(on, forKey: clipWatchKey)
        clipTimer?.invalidate()
        clipTimer = nil
        if on {
            clipChangeCount = -1
            startClipboardWatch()
        }
    }

    private func startClipboardWatch() {
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
    }

    private func pollClipboard() {
        let count = NSPasteboard.general.changeCount
        guard count != clipChangeCount else { return }
        clipChangeCount = count
        ingestClipboard()
    }

    func refreshFromClipboard() {
        ingestClipboard()
    }

    private func ingestClipboard() {
        guard clipboardWatchEnabled, !isDownloading, !isUpdatingApp else { return }
        guard let clip = NSPasteboard.general.string(forType: .string) else { return }
        let found = Sites.allURLs(in: clip).filter(Self.hasHost)
        guard !found.isEmpty else { return }
        let existing = Sites.allURLs(in: urlText)
        let fresh = found.filter { !existing.contains($0) && !autoAddedURLs.contains($0) }
        guard !fresh.isEmpty else { return }
        autoAddedURLs.formUnion(fresh)
        linkLines.append(contentsOf: fresh.map { LinkLine(text: $0) })
    }

    /// 只要能解析出带点的 host，就当作可下载链接（yt-dlp 本身支持大量站点，不再做站点白名单）。
    private static func hasHost(_ s: String) -> Bool {
        guard let url = URL(string: s), let host = url.host, let scheme = url.scheme else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        return host.contains(".")
    }

    func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDir
        panel.prompt = "选择"
        if panel.runModal() == .OK, let dir = panel.url {
            saveDir = dir
            UserDefaults.standard.set(dir.path, forKey: saveDirKey)
        }
    }

    func startDownload() {
        guard !isDownloading, !isUpdatingApp else { return }
        let links = Sites.allURLs(in: urlText)
        if links.count <= 1 {
            queueTotal = 0
            queueSummary = nil
            guard let only = links.first else { return }
            beginItem(only)
        } else {
            queueLinks = links
            queueTotal = links.count
            queueIndex = 0
            queueSucceeded = 0
            queueFailures = []
            queueSummary = nil
            lastFinishedName = ""
            lastError = ""
            startNextInQueue()
        }
    }

    private func startNextInQueue() {
        guard queueIndex < queueLinks.count else {
            finishQueue()
            return
        }
        let link = queueLinks[queueIndex]
        queueIndex += 1
        beginItem(link)
    }

    private func finishQueue() {
        isDownloading = false
        progress = 0
        statusLine = ""
        let summary = QueueSummary(succeeded: queueSucceeded,
                                   failed: queueFailures.count,
                                   failures: queueFailures.map { "\($0.link) —— \($0.message)" })
        queueSummary = summary
        Notify.send(title: summary.failed == 0 ? "队列下载成功" : "队列下载完成",
                    body: summary.failed == 0 ? "\(summary.succeeded) 个链接全部下载完成"
                                              : "成功 \(summary.succeeded) 个，失败 \(summary.failed) 个",
                    fileDir: saveDir)
        queueTotal = 0
        queueLinks = []
        queueFailures = []
    }

    private func resolveFailure(_ id: Int, _ link: String, _ msg: String) {
        if queueTotal > 0 {
            queueFailures.append((link, msg))
            isDownloading = false
            progress = 0
            startNextInQueue()
        } else {
            isDownloading = false
            progress = 0
            statusLine = ""
            lastError = msg
        }
    }

    private func beginItem(_ trimmed: String) {
        downloadID += 1
        let id = downloadID
        isDownloading = true
        progress = -1
        lastError = ""
        lastFinishedName = ""
        statusLine = "准备中…"

        let host = URL(string: trimmed)?.host ?? ""

        if Sites.isWechatChannels(host) {
            statusLine = "正在识别视频号…"
            WechatChannelsResolver.resolve(url: trimmed) { [weak self] result in
                Task { @MainActor in
                    guard let self, id == self.downloadID else { return }
                    let base = "VideoGrab 不支持下载视频号。"
                    switch result {
                    case .success(let r):
                        let t = r.title.count > 40 ? String(r.title.prefix(40)) + "…" : r.title
                        let who = r.author.isEmpty ? "" : "（\(r.author)）"
                        self.resolveFailure(id, trimmed, "已识别视频号视频《\(t)》\(who)。\n" + base)
                    case .failure(let err):
                        self.resolveFailure(id, trimmed, base + "\n（\(err.localizedDescription)）")
                    }
                }
            }
            return
        }

        if XinpianchangResolver.isXinpianchang(host) {
            statusLine = "正在解析新片场…"
            XinpianchangResolver.resolve(url: trimmed, quality: quality) { [weak self] result in
                Task { @MainActor in
                    guard let self, id == self.downloadID else { return }
                    switch result {
                    case .success(let r):
                        self.downloader.downloadDirect(mp4: r.mp4, title: r.title, quality: self.quality,
                                                       saveDir: self.saveDir,
                                                       onProgress: self.progressHandler(id),
                                                       onFinish: self.finishHandler(id, trimmed))
                    case .failure(let err):
                        self.resolveFailure(id, trimmed, err.localizedDescription)
                    }
                }
            }
            return
        }

        if Sites.isVimeo(host) {
            resolveFailure(id, trimmed, "Vimeo 视频现受 DRM 加密保护，暂不支持下载。")
            return
        }

        if Sites.isPinterest(host) {
            statusLine = "正在解析 Pinterest…"
            PinterestResolver.resolve(url: trimmed) { [weak self] outcome in
                Task { @MainActor in
                    guard let self, id == self.downloadID else { return }
                    switch outcome {
                    case .failure(let err):
                        self.resolveFailure(id, trimmed, err.localizedDescription)
                    case .success(let pin):
                        switch pin {
                        case .native:
                            self.downloader.download(url: trimmed, quality: self.quality, saveDir: self.saveDir,
                                                     onProgress: self.progressHandler(id),
                                                     onFinish: self.finishHandler(id, trimmed))
                        case .vimeo:
                            self.resolveFailure(id, trimmed,
                                                "该 Pinterest 视频实际是 Vimeo 外链；Vimeo 视频现受 DRM 加密保护，暂不支持下载。")
                        }
                    }
                }
            }
            return
        }

        downloader.download(url: trimmed, quality: quality, saveDir: saveDir,
                            onProgress: progressHandler(id), onFinish: finishHandler(id, trimmed))
    }

    private func progressHandler(_ id: Int) -> (Double?, String?) -> Void {
        { [weak self] pct, line in
            Task { @MainActor in
                guard let self, id == self.downloadID else { return }
                if let pct { self.progress = pct }
                if let line { self.statusLine = line }
            }
        }
    }

    private func finishHandler(_ id: Int, _ link: String) -> (DownloadResult) -> Void {
        { [weak self] result in
            Task { @MainActor in
                guard let self, id == self.downloadID else { return }
                self.progress = 0
                if self.queueTotal > 0 {
                    switch result {
                    case .success: self.queueSucceeded += 1
                    case .failure(let msg): self.queueFailures.append((link, msg))
                    }
                    self.isDownloading = false
                    self.statusLine = ""
                    self.startNextInQueue()
                } else {
                    self.isDownloading = false
                    switch result {
                    case .success(let name):
                        self.statusLine = "完成"
                        self.lastFinishedName = name
                        Notify.send(title: "下载完成", body: name, fileDir: self.saveDir)
                    case .failure(let msg):
                        self.statusLine = ""
                        self.lastError = msg
                    }
                }
            }
        }
    }

    func cancelDownload() {
        downloadID += 1
        downloader.cancel()
        isDownloading = false
        progress = 0
        statusLine = "已取消"
        if queueTotal > 0 {
            if queueSucceeded + queueFailures.count > 0 {
                queueSummary = QueueSummary(succeeded: queueSucceeded,
                                            failed: queueFailures.count,
                                            failures: queueFailures.map { "\($0.link) —— \($0.message)" })
            }
            queueTotal = 0
            queueLinks = []
            queueFailures = []
        }
    }

    func updateCore() {
        guard !updatingCore else { return }
        updatingCore = true
        statusLine = "正在更新下载内核…"
        downloader.updateCore { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.updatingCore = false
                self.statusLine = msg
                self.readCoreVersion()
            }
        }
    }

    private func readCoreVersion() {
        downloader.coreVersion { [weak self] v in
            Task { @MainActor in self?.coreVersion = v }
        }
    }

    // MARK: - 应用更新

    func checkForUpdates() {
        guard !checkingUpdate, !isUpdatingApp else { return }
        checkingUpdate = true
        if case .available = updateFlow {} else { updateFlow = .idle }
        updateMessage = ""
        UpdateChecker.check { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.checkingUpdate = false
                switch result {
                case .upToDate:
                    self.showTransientUpdateMessage("已是最新版本 v\(UpdateChecker.currentVersion)", error: false)
                case .available(let release):
                    self.pendingRelease = release
                    self.updateFlow = .available(release)
                case .failure(let msg):
                    self.showTransientUpdateMessage(msg, error: true)
                }
            }
        }
    }

    func startAutoUpdate() {
        guard case .available(let release) = updateFlow,
              let zip = release.zipURL, let hash = release.sha256,
              !isDownloading else { return }
        updateFlow = .downloading(0)
        SelfUpdater.shared.downloadAndInstall(zipURL: zip, sha256: hash, version: release.version) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .progress(let p):
                    if case .downloading = self.updateFlow { self.updateFlow = .downloading(p) }
                case .installing:
                    self.updateFlow = .installing
                case .failed(let msg):
                    if let pending = self.pendingRelease { self.updateFlow = .available(pending) }
                    self.showTransientUpdateMessage(msg, error: true)
                case .cancelled:
                    if let pending = self.pendingRelease { self.updateFlow = .available(pending) }
                }
            }
        }
    }

    func cancelAutoUpdate() {
        guard case .downloading = updateFlow else { return }
        SelfUpdater.shared.cancel()
    }

    var showUpdateBanner: Bool {
        if case .idle = updateFlow { return false }
        return true
    }

    private func showTransientUpdateMessage(_ msg: String, error: Bool) {
        updateIsError = error
        updateMessage = msg
        clearUpdateMsgTask?.cancel()
        clearUpdateMsgTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            updateMessage = ""
        }
    }

    func openReleasePage() {
        let url: URL?
        switch updateFlow {
        case .available(let release): url = release.pageURL
        default: url = pendingRelease?.pageURL
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    func dismissRelease() {
        if case .downloading = updateFlow {
            SelfUpdater.shared.cancel()
        }
        if case .installing = updateFlow { return }
        updateFlow = .idle
    }
}

struct QueueSummary: Equatable {
    let succeeded: Int
    let failed: Int
    let failures: [String]
}

enum UpdateFlow: Equatable {
    case idle
    case available(UpdateChecker.Release)
    case downloading(Double)
    case installing
}
