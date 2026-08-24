import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    // 用户输入 / 自动识别的链接
    @Published var url: String = ""
    // 画质选择，默认最高
    @Published var quality: Quality = .best
    // 保存目录
    @Published var saveDir: URL

    // 下载状态
    @Published var isDownloading = false
    @Published var progress: Double = 0          // 0...1，-1 表示进度未知
    @Published var statusLine: String = ""       // 当前阶段/速度等
    @Published var lastError: String = ""
    @Published var lastFinishedName: String = "" // 上次成功下载的文件名

    // 内核更新状态
    @Published var updatingCore = false
    @Published var coreVersion: String = ""

    // 应用更新状态（「检查更新」按钮）
    @Published var checkingUpdate = false
    @Published var updateMessage = ""          // 「已是最新」/错误提示，几秒后自动消失
    @Published var updateIsError = false
    @Published var newRelease: UpdateChecker.Release?

    private let downloader = Downloader()
    private let saveDirKey = "VideoGrab.saveDir"
    // 递增代数：取消后旧下载的回调仍可能晚到（子进程退出、网络解析返回），
    // 回调凭代数自证未过期，过期的直接丢弃——否则会污染新一轮下载的进度/状态
    private var downloadID = 0

    // 批量队列：queueTotal > 0 表示队列进行中
    @Published var queueTotal = 0              // 队列任务总数；0 = 单任务模式
    @Published var queueIndex = 0              // 已启动的任务数（含进行中的那个）
    @Published var queueSummary: QueueSummary? // 队列结束后的汇总卡片
    private var queueLinks: [String] = []
    private var queueSucceeded = 0
    private var queueFailures: [(link: String, message: String)] = []
    private var clearUpdateMsgTask: Task<Void, Never>?

    // 剪贴板监听：App 常驻后台轮询 changeCount，用户在浏览器里每复制一条链接就自动进框，
    // 无需开关弹窗。系统剪贴板只保留最后一次复制，所以必须实时接住。
    private var clipChangeCount = -1            // -1 = 首轮强制读一次（接管启动前已复制的链接）
    private var clipTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: saveDirKey) {
            saveDir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        readCoreVersion()
        Notify.bootstrap()
        // 启动时预热 Chrome 钥匙串授权（下 B站要读 Cookie），让用户一次性点「始终允许」
        downloader.prewarmCookieAccess()
        startClipboardWatch()
    }

    deinit { clipTimer?.invalidate() }

    private func startClipboardWatch() {
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
    }

    private func pollClipboard() {
        let count = NSPasteboard.general.changeCount
        guard count != clipChangeCount else { return }   // 没变化不解析
        clipChangeCount = count
        ingestClipboard()
    }

    // 把剪贴板里的链接「增量」带入输入框：
    // 只追加新链接——框里已有的、之前已经自动带过的不重复；用户手动删掉的也不会被塞回来。
    private var autoAddedURLs: Set<String> = []

    /// 弹窗打开时也走一遍（兜底：计时器间隙里的复制不会漏）
    func refreshFromClipboard() {
        ingestClipboard()
    }

    private func ingestClipboard() {
        guard let clip = NSPasteboard.general.string(forType: .string) else { return }
        let found = Sites.allURLs(in: clip)
        guard !found.isEmpty else { return }
        let existing = Sites.allURLs(in: url)
        let fresh = found.filter { !existing.contains($0) && !autoAddedURLs.contains($0) }
        guard !fresh.isEmpty else { return }
        autoAddedURLs.formUnion(fresh)
        if url.isEmpty {
            url = fresh.joined(separator: "\n")
        } else {
            url += "\n" + fresh.joined(separator: "\n")
        }
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
        guard !isDownloading else { return }
        let links = Sites.allURLs(in: url)
        if links.count <= 1 {
            // 单链接：行为与以前一致（完成时发单条「下载完成」通知）
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

    // 队列收尾：整个队列只发一次汇总通知，不逐条打扰
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

    /// 某个任务以「未发起下载的失败」告终（视频号不支持、解析失败等）：
    /// 单任务模式照旧在界面报错；队列模式记一笔后继续下一个。
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
        let id = downloadID              // 本轮下载的代数
        isDownloading = true
        progress = -1
        lastError = ""
        lastFinishedName = ""
        statusLine = "准备中…"

        let host = URL(string: trimmed)?.host ?? ""

        // 视频号没有公开下载接口（视频直链 + 解密种子在微信客户端里，且文件本身加密），
        // 这里只做识别 + 明确报错，避免误走「需要本地代理」或 yt-dlp 的「Unsupported URL」。
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

        // 新片场文章页有 JS 反爬：先走移动端接口解析出预签名直链，再用 URLSession 直下
        // （这类签名 URL 过 yt-dlp 会因 URL 规范化破坏签名而 403）
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

        // Vimeo 被 Cloudflare Turnstile + 匿名 OAuth 401 双重挡住，yt-dlp 提取器已坏，
        // 走专用解析器（无头 Chrome 过验证 + DASH 分片重组）。
        if Sites.isVimeo(host) {
            statusLine = "正在解析 Vimeo…"
            downloader.downloadVimeo(url: trimmed, quality: quality, saveDir: saveDir,
                                     onProgress: progressHandler(id), onFinish: finishHandler(id, trimmed))
            return
        }

        // Pinterest：原生视频（pinimg CDN）直接交给 yt-dlp；Vimeo 来源的 pin 转 Vimeo 解析器。
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
                        case .vimeo(let vimeoURL):
                            self.statusLine = "正在解析 Vimeo…"
                            self.downloader.downloadVimeo(url: vimeoURL, quality: self.quality, saveDir: self.saveDir,
                                                          onProgress: self.progressHandler(id),
                                                          onFinish: self.finishHandler(id, trimmed))
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
                guard let self, id == self.downloadID else { return }   // 过期回调丢弃
                if let pct { self.progress = pct }
                if let line { self.statusLine = line }
            }
        }
    }

    private func finishHandler(_ id: Int, _ link: String) -> (DownloadResult) -> Void {
        { [weak self] result in
            Task { @MainActor in
                guard let self, id == self.downloadID else { return }   // 过期回调丢弃
                self.progress = 0
                if self.queueTotal > 0 {
                    // 队列模式：不逐条通知、不弹结果卡，静默记账后继续下一个
                    switch result {
                    case .success:  self.queueSucceeded += 1
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
        downloadID += 1   // 先作废所有在途回调，再停底层任务；晚到的旧回调会被代数检查挡住
        downloader.cancel()
        isDownloading = false
        progress = 0
        statusLine = "已取消"
        if queueTotal > 0 {           // 连剩余队列一起取消
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

    // MARK: - 应用更新检查

    func checkForUpdates() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        newRelease = nil
        updateMessage = ""
        UpdateChecker.check { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.checkingUpdate = false
                switch result {
                case .upToDate:
                    self.showTransientUpdateMessage("已是最新版本 v\(UpdateChecker.currentVersion)", error: false)
                case .available(let release):
                    self.newRelease = release
                case .failure(let msg):
                    self.showTransientUpdateMessage(msg, error: true)
                }
            }
        }
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
        guard let release = newRelease else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    func dismissRelease() {
        newRelease = nil
    }

}

// 队列结束后的汇总（结果卡片数据）
struct QueueSummary: Equatable {
    let succeeded: Int
    let failed: Int
    let failures: [String]   // 「链接 —— 错误」行
}
