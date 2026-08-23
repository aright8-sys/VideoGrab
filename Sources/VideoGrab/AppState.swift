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

    private let downloader = Downloader()
    private let saveDirKey = "VideoGrab.saveDir"
    // 递增代数：取消后旧下载的回调仍可能晚到（子进程退出、网络解析返回），
    // 回调凭代数自证未过期，过期的直接丢弃——否则会污染新一轮下载的进度/状态
    private var downloadID = 0

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
    }

    // 菜单弹出时调用：把剪贴板里的视频链接预填进去
    func refreshFromClipboard() {
        guard !isDownloading else { return }
        guard let clip = NSPasteboard.general.string(forType: .string) else { return }
        guard let found = Sites.firstURL(in: clip) else { return }
        // 只有当前框为空、或框里也是个自动识别来的链接时才覆盖，避免打断用户手动编辑
        if url.isEmpty || Sites.firstURL(in: url) != nil {
            url = found
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
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isDownloading else { return }
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
                    self.isDownloading = false
                    self.progress = 0
                    self.statusLine = ""
                    let base = "VideoGrab 不支持下载视频号。"
                    switch result {
                    case .success(let r):
                        let t = r.title.count > 40 ? String(r.title.prefix(40)) + "…" : r.title
                        let who = r.author.isEmpty ? "" : "（\(r.author)）"
                        self.lastError = "已识别视频号视频《\(t)》\(who)。\n" + base
                    case .failure(let err):
                        self.lastError = base + "\n（\(err.localizedDescription)）"
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
                                                       onFinish: self.finishHandler(id))
                    case .failure(let err):
                        self.isDownloading = false
                        self.progress = 0
                        self.statusLine = ""
                        self.lastError = err.localizedDescription
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
                                     onProgress: progressHandler(id), onFinish: finishHandler(id))
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
                        self.isDownloading = false
                        self.progress = 0
                        self.statusLine = ""
                        self.lastError = err.localizedDescription
                    case .success(let pin):
                        switch pin {
                        case .native:
                            self.downloader.download(url: trimmed, quality: self.quality, saveDir: self.saveDir,
                                                     onProgress: self.progressHandler(id),
                                                     onFinish: self.finishHandler(id))
                        case .vimeo(let vimeoURL):
                            self.statusLine = "正在解析 Vimeo…"
                            self.downloader.downloadVimeo(url: vimeoURL, quality: self.quality, saveDir: self.saveDir,
                                                          onProgress: self.progressHandler(id),
                                                          onFinish: self.finishHandler(id))
                        }
                    }
                }
            }
            return
        }

        downloader.download(url: trimmed, quality: quality, saveDir: saveDir,
                            onProgress: progressHandler(id), onFinish: finishHandler(id))
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

    private func finishHandler(_ id: Int) -> (DownloadResult) -> Void {
        { [weak self] result in
            Task { @MainActor in
                guard let self, id == self.downloadID else { return }   // 过期回调丢弃
                self.isDownloading = false
                self.progress = 0
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

    func cancelDownload() {
        downloadID += 1   // 先作废所有在途回调，再停底层任务；晚到的旧回调会被代数检查挡住
        downloader.cancel()
        isDownloading = false
        progress = 0
        statusLine = "已取消"
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
}
