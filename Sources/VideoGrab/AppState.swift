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
        guard let found = Sites.firstSupportedURL(in: clip) else { return }
        // 只有当前框为空、或框里也是个自动识别来的链接时才覆盖，避免打断用户手动编辑
        if url.isEmpty || Sites.firstSupportedURL(in: url) != nil {
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
        isDownloading = true
        progress = -1
        lastError = ""
        lastFinishedName = ""
        statusLine = "准备中…"

        downloader.download(url: trimmed, quality: quality, saveDir: saveDir,
            onProgress: { [weak self] pct, line in
                Task { @MainActor in
                    if let pct { self?.progress = pct }
                    if let line { self?.statusLine = line }
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
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
            })
    }

    func cancelDownload() {
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
