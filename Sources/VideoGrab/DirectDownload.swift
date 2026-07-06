import Foundation

// 新片场直链是 CDN 预签名 URL：签名算在 query 的百分号编码原文上（%7B%22…）。
// yt-dlp 的 generic 提取器会把 URL 规范化、把 %7B 解回 {，签名就对不上 → 403。
// 所以这类签名直链不能过 yt-dlp，直接用 URLSession 按字节原样请求（带 Referer、强制直连）。
final class DirectDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private let referer: String
    private let dest: URL              // 最终落地文件（视频）
    private let audioFFmpeg: String?   // 非 nil 表示要抽成 mp3，值为 ffmpeg 可执行路径
    private var onProgress: ((Double?, String?) -> Void)?
    private var onFinish: ((DownloadResult) -> Void)?
    private var finished = false

    init(referer: String, dest: URL, audioFFmpeg: String?) {
        self.referer = referer
        self.dest = dest
        self.audioFFmpeg = audioFFmpeg
    }

    func start(url: String,
               onProgress: @escaping (Double?, String?) -> Void,
               onFinish: @escaping (DownloadResult) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        guard let u = URL(string: url) else { complete(.failure("直链无效")); return }

        // 强制直连：国内站走 Clash 会被截断，且预签名 URL 绑定直连出口 IP
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
        ]
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        var req = URLRequest(url: u)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        // 该 CDN 只接受带 Range 的请求，全量 GET 直接 403；bytes=0- 即整文件
        req.setValue("bytes=0-", forHTTPHeaderField: "Range")
        onProgress(nil, "下载中…")
        session.downloadTask(with: req).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mb = Double(totalBytesWritten) / 1_048_576
        onProgress?(pct, String(format: "下载中 %.0f%%（%.1f MB）", pct * 100, mb))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            complete(.failure("直链下载失败：HTTP \(http.statusCode)")); return
        }
        let fm = FileManager.default
        do {
            if let ffmpeg = audioFFmpeg {
                // 先落临时 mp4，再抽 mp3
                let tmpMp4 = dest.deletingPathExtension().appendingPathExtension("src.mp4")
                try? fm.removeItem(at: tmpMp4)
                try fm.moveItem(at: location, to: tmpMp4)
                extractAudio(ffmpeg: ffmpeg, from: tmpMp4)
            } else {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: location, to: dest)
                complete(.success(dest.lastPathComponent))
            }
        } catch {
            complete(.failure("保存文件失败：\(error.localizedDescription)"))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            complete(.failure("直链下载失败：\(error.localizedDescription)"))
        }
    }

    // MARK: - 音频抽取

    private func extractAudio(ffmpeg: String, from mp4: URL) {
        onProgress?(nil, "正在提取音频…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", mp4.path, "-vn",
                       "-c:a", "libmp3lame", "-q:a", "0", dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            try? FileManager.default.removeItem(at: mp4)
            if proc.terminationStatus == 0 {
                self.complete(.success(self.dest.lastPathComponent))
            } else {
                self.complete(.failure("音频提取失败（ffmpeg 退出码 \(proc.terminationStatus)）"))
            }
        }
        do { try p.run() } catch { complete(.failure("启动 ffmpeg 失败：\(error.localizedDescription)")) }
    }

    private func complete(_ r: DownloadResult) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        onFinish?(r)
    }
}
