import Foundation
import Darwin

enum Quality: String, CaseIterable, Identifiable {
    case best = "最高画质"
    case p1080 = "1080p"
    case p720 = "720p"
    case audio = "仅音频 (MP3)"

    var id: String { rawValue }

    // 画质选择器上显示的简短标签
    var shortLabel: String {
        switch self {
        case .best:  return "最高"
        case .p1080: return "1080p"
        case .p720:  return "720p"
        case .audio: return "音频"
        }
    }

    // 画质选择器上的图标
    var icon: String {
        switch self {
        case .best:  return "sparkles"
        case .p1080: return "4k.tv"
        case .p720:  return "tv"
        case .audio: return "music.note"
        }
    }

    // 传给 yt-dlp 的格式/输出参数
    var formatArgs: [String] {
        switch self {
        case .best:
            return ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
        case .p1080:
            return ["-f", "bv*[height<=1080]+ba/b[height<=1080]", "--merge-output-format", "mp4"]
        case .p720:
            return ["-f", "bv*[height<=720]+ba/b[height<=720]", "--merge-output-format", "mp4"]
        case .audio:
            return ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
    }
}

enum DownloadResult {
    case success(String)   // 文件名
    case failure(String)   // 错误信息
}

final class Downloader {
    private var process: Process?
    private let appSupportBin: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VideoGrab/bin", isDirectory: true)
    }()

    // MARK: - 二进制路径解析

    // 优先用 App Support 里可自更新的内核，其次用 .app 内打包的，最后回退到 brew 路径（仅开发用）
    private func ytDlpPath() -> String? {
        ensureBundledBinaries()
        var candidates: [String] = [appSupportBin.appendingPathComponent("yt-dlp").path]
        if let b = bundledBinDir()?.appendingPathComponent("yt-dlp").path { candidates.append(b) }
        candidates += ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func ffmpegDir() -> String? {
        ensureBundledBinaries()
        var candidates: [String] = [appSupportBin.path]
        if let b = bundledBinDir()?.path { candidates.append(b) }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") }
    }

    private func bundledBinDir() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
    }

    // MARK: - 代理路由（关键）
    //
    // 国内站点（B站/新片场）必须直连——走 Clash 代理会被截断连接；
    // 国外站点（YouTube 等）必须走本地代理——直连会超时。
    // GUI App 不继承 shell 的 *_proxy 环境变量，所以这里自动探测本地代理端口。

    // 探测常见的本地代理端口（Clash/mihomo 默认 7897/7890 等）
    private func detectLocalProxy() -> String? {
        for port in [7897, 7890, 7891, 1087, 8080, 8888] {
            if Self.isPortOpen(port: port) { return "http://127.0.0.1:\(port)" }
        }
        return nil
    }

    private static func isPortOpen(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0   // 本地连接会立即成功或被拒绝，无需超时控制
    }

    // 按目标主机决定 --proxy 参数
    private func proxyArgs(forHost host: String) -> [String]? {
        if Sites.isCNHost(host) { return ["--proxy", ""] }      // 直连
        if let p = detectLocalProxy() { return ["--proxy", p] } // 走本地代理
        return nil                                                // 国外站且未探测到代理
    }

    // 去掉继承来的代理环境变量，让 --proxy 参数说了算（行为与启动方式无关）
    private func cleanedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "no_proxy",
                  "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "FTP_PROXY", "NO_PROXY",
                  "CLASH_PROXY"] {
            env[k] = nil
        }
        if let ff = ffmpegDir() {
            env["PATH"] = ff + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        return env
    }

    // 在 App 启动时预热 Chrome 钥匙串授权，弹一次「始终允许」即可，之后下 B站静默读 Cookie
    func prewarmCookieAccess() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Chrome Safe Storage", "-w"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    // 首次运行把打包的 yt-dlp + ffmpeg 拷到 App Support（可写、可自更新）
    private func ensureBundledBinaries() {
        let fm = FileManager.default
        guard let bundledDir = bundledBinDir() else { return }
        try? fm.createDirectory(at: appSupportBin, withIntermediateDirectories: true)
        for name in ["yt-dlp", "ffmpeg"] {
            let src = bundledDir.appendingPathComponent(name)
            guard fm.isExecutableFile(atPath: src.path) else { continue }
            let dst = appSupportBin.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue } // 已存在不覆盖；yt-dlp 升级走「更新内核」
            try? fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    // MARK: - 下载

    func download(url: String, quality: Quality, saveDir: URL,
                  onProgress: @escaping (Double?, String?) -> Void,
                  onFinish: @escaping (DownloadResult) -> Void) {
        guard let ytDlp = ytDlpPath() else {
            onFinish(.failure("找不到 yt-dlp，请重新构建 App。"))
            return
        }
        guard ffmpegDir() != nil else {
            onFinish(.failure("找不到 ffmpeg，请重新构建 App。"))
            return
        }

        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: normalized)?.host ?? ""

        guard let proxy = proxyArgs(forHost: host) else {
            onFinish(.failure("YouTube 等国外站点需要本地代理（Clash 等）。请先启动代理，或确认端口为 7897/7890。"))
            return
        }

        var args = quality.formatArgs
        args += proxy
        // B站/小红书需要登录态才能过风控/拿高清，自动读 Chrome Cookie
        if Sites.needsCookies(host) {
            args += ["--cookies-from-browser", "chrome"]
        }
        args += ["--newline", "--no-playlist",
                 "--socket-timeout", "30", "--retries", "5", "--fragment-retries", "5",
                 "-o", saveDir.appendingPathComponent("%(title)s.%(ext)s").path]
        if let ff = ffmpegDir() {
            args += ["--ffmpeg-location", ff]
        }
        args.append(normalized)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytDlp)
        proc.arguments = args
        proc.environment = cleanedEnv()

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        var finalName = ""
        var tail: [String] = []   // 保留最后若干行用于报错
        var lastError = ""        // 单独记下 ERROR 行，报错时优先展示
        var buffer = Data()
        // 所有输出解析串行化到这条队列，避免 readability/termination 两处竞争 buffer
        let outQueue = DispatchQueue(label: "com.local.VideoGrab.output")

        func handleLine(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            tail.append(trimmed)
            if tail.count > 20 { tail.removeFirst() }
            if trimmed.hasPrefix("ERROR") { lastError = trimmed }
            if let name = Self.parseDestination(trimmed) { finalName = name }

            if let pct = Self.parsePercent(trimmed) {
                onProgress(pct, trimmed)
            } else if trimmed.hasPrefix("[") || trimmed.hasPrefix("ERROR") {
                onProgress(nil, trimmed)
            }
        }

        // yt-dlp 进度用 \r，普通日志用 \n —— 两者都当分隔符；flushAll 时把残余当作最后一行
        func drain(_ data: Data, flushAll: Bool) {
            buffer.append(data)
            while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                if let line = String(data: lineData, encoding: .utf8) { handleLine(line) }
            }
            if flushAll, !buffer.isEmpty {
                if let line = String(data: buffer, encoding: .utf8) { handleLine(line) }
                buffer.removeAll()
            }
        }

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { return }
            outQueue.async { drain(chunk, flushAll: false) }
        }

        proc.terminationHandler = { p in
            handle.readabilityHandler = nil
            let rest = (try? handle.readToEnd()) ?? Data()   // 排空残余，确保最后的 ERROR 行不丢
            outQueue.async {
                drain(rest, flushAll: true)
                if p.terminationStatus == 0 {
                    onFinish(.success(finalName.isEmpty ? "下载完成" : finalName))
                } else if p.terminationStatus == 15 || p.terminationStatus == 9 {
                    // 被取消，不回调
                } else if !lastError.isEmpty {
                    onFinish(.failure(lastError))
                } else {
                    let msg = tail.suffix(6).joined(separator: "\n")
                    onFinish(.failure(msg.isEmpty ? "下载失败（退出码 \(p.terminationStatus)）" : msg))
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            onFinish(.failure("启动失败：\(error.localizedDescription)"))
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
    }

    // MARK: - 内核版本 / 更新

    func coreVersion(_ done: @escaping (String) -> Void) {
        guard let ytDlp = ytDlpPath() else { done("未安装"); return }
        runCapture(exe: ytDlp, args: ["--version"]) { out, _ in
            done(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func updateCore(_ done: @escaping (String) -> Void) {
        guard let ytDlp = ytDlpPath() else { done("找不到 yt-dlp"); return }
        // yt-dlp -U 从 GitHub 拉更新，属国外站点，走本地代理（探测不到则直连）
        var args = ["-U"]
        if let p = detectLocalProxy() { args += ["--proxy", p] }
        runCapture(exe: ytDlp, args: args) { out, code in
            let last = out.split(separator: "\n").last.map(String.init) ?? out
            done(code == 0 ? "内核已是最新或已更新：\(last)" : "更新失败：\(last)")
        }
    }

    private func runCapture(exe: String, args: [String], done: @escaping (String, Int32) -> Void) {
        let env = cleanedEnv()
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            proc.arguments = args
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                done(String(data: data, encoding: .utf8) ?? "", proc.terminationStatus)
            } catch {
                done("执行失败：\(error.localizedDescription)", -1)
            }
        }
    }

    // MARK: - 解析

    static func parsePercent(_ line: String) -> Double? {
        // [download]   5.2% of   19.31MiB at ...
        guard line.contains("[download]"), let r = line.range(of: "%") else { return nil }
        let head = line[line.startIndex..<r.lowerBound]
        let numStr = head.reversed().prefix { $0.isNumber || $0 == "." }
        let s = String(numStr.reversed())
        guard let v = Double(s) else { return nil }
        return min(max(v / 100.0, 0), 1)
    }

    static func parseDestination(_ line: String) -> String? {
        // [download] Destination: /path/x.mp4   或   [ExtractAudio] Destination: ...
        if let r = line.range(of: "Destination: ") {
            return (String(line[r.upperBound...]) as NSString).lastPathComponent
        }
        // [Merger] Merging formats into "/path/x.mp4"
        if line.contains("Merging formats into") {
            if let first = line.range(of: "\""), let last = line.range(of: "\"", options: .backwards),
               first.upperBound <= last.lowerBound {
                return (String(line[first.upperBound..<last.lowerBound]) as NSString).lastPathComponent
            }
        }
        return nil
    }
}
