import Foundation

// Vimeo 专用下载：无头 Chrome 过 Cloudflare Turnstile 拿到 DASH playlist.json 签名地址，
// 再按 playlist.json 里的 fMP4 分片（init segment + segment.m4s）重组视频/音轨，
// 最后用 ffmpeg 封装成标准 mp4。
//
// yt-dlp 的 Vimeo 提取器目前坏了（匿名 OAuth 端点 401 + watch 页 Cloudflare 挑战），
// 所以 Vimeo 链接走这里，而不是通用 yt-dlp 路径。
final class VimeoDownloader {
    struct Track {
        let id: String
        let baseURL: String
        let height: Int
        let bitrate: Int
        let initSegment: Data
        let segments: [String]
    }

    struct Manifest {
        let remuxRoot: String
        let video: [Track]
        let audio: [Track]
    }

    private struct Resolved {
        let playlistURL: String
        let title: String
    }

    private final class ResolveBox {
        var playlist: String?
        var title: String?
        var done = false
    }

    enum VimeoError: LocalizedError, Equatable {
        case network(String)
        case noMedia
        case cancelled

        var errorDescription: String? {
            switch self {
            case .network(let m): return "Vimeo 下载失败：\(m)"
            case .noMedia:        return "Vimeo 未找到可下载的媒体流。"
            case .cancelled:      return "已取消"
            }
        }
    }

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
    // 取页面标题：优先 og:title；document.title 若是 Cloudflare 挑战页则视为无效。
    // 返回空串表示「还没有有效标题」，调用方继续重试。
    private static let titleJS = """
        (() => {
          const og = document.querySelector('meta[property="og:title"]')?.content || '';
          if (og.trim()) return og;
          const t = document.title || '';
          return /just a moment|attention required/i.test(t) ? '' : t;
        })()
        """

    private static func extractTitle(_ res: Result<[String: Any], Error>) -> String? {
        guard case .success(let obj) = res,
              let cmdResult = obj["result"] as? [String: Any],
              let evalResult = cmdResult["result"] as? [String: Any],
              let v = evalResult["value"] as? String else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var chrome: ChromeCDP?
    private var session: URLSession?
    private var ffmpegProcess: Process?
    private var cancelled = false

    func cancel() {
        cancelled = true
        chrome?.stop()
        chrome = nil
        session?.invalidateAndCancel()
        session = nil
        ffmpegProcess?.terminate()
        ffmpegProcess = nil
    }

    func start(url: String, quality: Quality, saveDir: URL, ffmpeg: String,
               onProgress: @escaping (Double?, String?) -> Void,
               onFinish: @escaping (DownloadResult) -> Void) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)

        onProgress(nil, "正在启动浏览器解析 Vimeo…")
        resolve(url: url) { [weak self] result in
            guard let self else { return }
            self.chrome = nil   // 解析阶段结束，释放 Chrome 引用，避免循环持有
            switch result {
            case .failure(let err):
                if (err as? VimeoError) == .cancelled { return }
                onFinish(.failure(err.localizedDescription))
            case .success(let r):
                self.download(resolved: r, quality: quality, saveDir: saveDir, ffmpeg: ffmpeg,
                              onProgress: onProgress, onFinish: onFinish)
            }
        }
    }

    // MARK: - 解析（无头 Chrome → playlist.json + 标题）

    private func resolve(url: String, completion: @escaping (Result<Resolved, Error>) -> Void) {
        let chrome: ChromeCDP
        do {
            chrome = try ChromeCDP()
            self.chrome = chrome
        } catch {
            completion(.failure(error)); return
        }

        let box = ResolveBox()
        let stateQueue = DispatchQueue(label: "com.local.VideoGrab.vimeo.resolve")

        func finish(_ result: Result<Resolved, Error>) {
            stateQueue.async {
                guard !box.done else { return }
                box.done = true
                chrome.stop()
                completion(result)
            }
        }

        stateQueue.asyncAfter(deadline: .now() + 45) {
            finish(.failure(VimeoError.network("解析超时（可能被风控拦截，请重试）。")))
        }

        chrome.onEvent { method, params in
            guard method == "Network.responseReceived" else { return }
            let resp = params["response"] as? [String: Any]
            let u = (resp?["url"] as? String) ?? ""
            guard u.contains("playlist.json") else { return }
            stateQueue.async {
                guard !box.done else { return }
                box.playlist = u
                if let t = box.title {
                    finish(.success(Resolved(playlistURL: u, title: t)))
                }
            }
        }

        chrome.launch { [weak self] launchErr in
            if let launchErr { finish(.failure(launchErr)); return }
            guard let chrome = self?.chrome else { return }
            chrome.send("Page.addScriptToEvaluateOnNewDocument",
                        params: ["source": "Object.defineProperty(navigator,'webdriver',{get:()=>undefined});"]) { _ in
                chrome.send("Network.enable") { _ in
                    chrome.send("Page.navigate", params: ["url": url]) { _ in }
                }
            }
            // 触发播放以让播放器拉取媒体清单（headless 下 autoplay 常被拦，muted 播放可绕过）
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                chrome.send("Runtime.evaluate",
                            params: ["expression": "(()=>{const v=document.querySelector('video');if(v){v.muted=true;v.play().catch(()=>{});return 1}return 0})()",
                                     "returnByValue": true]) { _ in }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 7) {
                chrome.send("Runtime.evaluate",
                            params: ["expression": "(()=>{const v=document.querySelector('video');if(v){v.muted=true;v.play().catch(()=>{});return 1}return 0})()",
                                     "returnByValue": true]) { _ in }
            }
            // 标题轮询：页面一就绪就取 og:title，不死等固定秒数（旧实现固定 sleep 8s，
            // 每个下载白等好几秒）。Cloudflare 挑战期取不到有效标题就 1 秒后重试；
            // 与 playlist.json 凑齐即完成解析，整体超时仍由上面的 45s 兜底。
            func pollTitle(_ attempt: Int) {
                stateQueue.async {
                    guard !box.done, attempt < 20 else { return }
                    chrome.send("Runtime.evaluate", params: ["expression": Self.titleJS, "returnByValue": true]) { res in
                        let title = Self.extractTitle(res)
                        stateQueue.async {
                            guard !box.done else { return }
                            if let t = title {
                                box.title = t
                                if let p = box.playlist {
                                    finish(.success(Resolved(playlistURL: p, title: t)))
                                }
                            } else {
                                stateQueue.asyncAfter(deadline: .now() + 1.0) { pollTitle(attempt + 1) }
                            }
                        }
                    }
                }
            }
            pollTitle(0)
        }
    }

    // MARK: - 下载 + 重组 + 封装

    private func download(resolved: Resolved, quality: Quality, saveDir: URL, ffmpeg: String,
                          onProgress: @escaping (Double?, String?) -> Void,
                          onFinish: @escaping (DownloadResult) -> Void) {
        onProgress(nil, "获取 Vimeo 媒体清单…")
        guard let url = URL(string: resolved.playlistURL) else {
            onFinish(.failure("Vimeo 媒体清单地址无效。")); return
        }
        var req = URLRequest(url: url)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://player.vimeo.com/", forHTTPHeaderField: "Referer")

        session?.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if self.cancelled { return }
            if let err { onFinish(.failure("获取 Vimeo 媒体清单失败：\(err.localizedDescription)")); return }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                onFinish(.failure("获取 Vimeo 媒体清单失败：HTTP \(code)")); return
            }
            guard let data, let manifest = self.parseManifest(data, playlistURL: resolved.playlistURL) else {
                onFinish(.failure("Vimeo 媒体清单解析失败。")); return
            }
            self.reassemble(manifest: manifest, title: resolved.title, quality: quality,
                            saveDir: saveDir, ffmpeg: ffmpeg, onProgress: onProgress, onFinish: onFinish)
        }.resume()
    }

    func parseManifest(_ data: Data, playlistURL: String) -> Manifest? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let remuxRoot = playlistURL.components(separatedBy: "/v2/playlist/av/primary/playlist.json").first! + "/v2/remux/avf/"

        func tracks(_ key: String) -> [Track] {
            guard let arr = obj[key] as? [[String: Any]] else { return [] }
            return arr.compactMap { t in
                guard let id = t["id"] as? String,
                      let base = t["base_url"] as? String,
                      let initB64 = t["init_segment"] as? String,
                      let initData = Data(base64Encoded: initB64),
                      let segs = t["segments"] as? [[String: Any]] else { return nil }
                let urls = segs.compactMap { $0["url"] as? String }
                guard urls.count == segs.count, !urls.isEmpty else { return nil }
                return Track(id: id, baseURL: base,
                             height: (t["height"] as? Int) ?? 0,
                             bitrate: (t["bitrate"] as? Int) ?? 0,
                             initSegment: initData, segments: urls)
            }
        }
        return Manifest(remuxRoot: remuxRoot, video: tracks("video"), audio: tracks("audio"))
    }

    private func pickVideo(_ tracks: [Track], _ quality: Quality) -> Track? {
        guard !tracks.isEmpty else { return nil }
        if quality == .audio { return nil }
        let cap: Int
        switch quality {
        case .p720:  cap = 720
        case .p1080: cap = 1080
        case .best, .audio: cap = .max
        }
        let usable = tracks.filter { $0.height <= cap }
        let pool = usable.isEmpty ? tracks : usable
        return pool.max(by: { a, b in
            a.height != b.height ? a.height < b.height : a.bitrate < b.bitrate
        })
    }

    private func pickAudio(_ tracks: [Track]) -> Track? {
        tracks.max(by: { $0.bitrate < $1.bitrate })
    }

    private func reassemble(manifest: Manifest, title: String, quality: Quality, saveDir: URL,
                            ffmpeg: String,
                            onProgress: @escaping (Double?, String?) -> Void,
                            onFinish: @escaping (DownloadResult) -> Void) {
        let video = pickVideo(manifest.video, quality)
        let audio = pickAudio(manifest.audio)
        guard audio != nil || video != nil else {
            onFinish(.failure(VimeoError.noMedia.localizedDescription)); return
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-vimeo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let totalSegs = (video?.segments.count ?? 0) + (audio?.segments.count ?? 0)
        var doneSegs = 0
        let progressLock = NSLock()

        func bumpProgress(_ n: Int = 1, _ line: String? = nil) {
            progressLock.lock(); doneSegs += n; let pct = Double(doneSegs) / Double(max(totalSegs, 1)); progressLock.unlock()
            onProgress(min(pct, 1), line ?? String(format: "下载分片 %.0f%%", pct * 100))
        }

        func downloadTrack(_ track: Track, name: String,
                           done: @escaping (Result<URL, Error>) -> Void) {
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                // 流式落盘：init segment 先写好，分片边下边追加。
                // 内存占用恒定，不再把整条轨攒在内存里最后一次性写出。
                let out = workDir.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: out.path, contents: track.initSegment),
                      let fh = try? FileHandle(forWritingTo: out) else {
                    done(.failure(VimeoError.network("写入临时文件失败"))); return
                }
                defer { try? fh.close() }

                // 分片按批并发：每批同时抓 4 个、按原顺序落盘。比逐个串行快约 4 倍，
                // 又不至于对 CDN 形成连接风暴；失败的分片自动重试一次。
                let concurrency = 4
                var start = 0
                while start < track.segments.count {
                    if self.cancelled { done(.failure(VimeoError.cancelled)); return }
                    let batch = Array(track.segments[start..<min(start + concurrency, track.segments.count)])
                    var datas = [Data?](repeating: nil, count: batch.count)
                    let dataLock = NSLock()
                    let bg = DispatchGroup()
                    for (j, seg) in batch.enumerated() {
                        bg.enter()
                        DispatchQueue.global().async {
                            defer { bg.leave() }
                            let urlStr = manifest.remuxRoot + track.baseURL + seg
                            let d = self.fetchDataSync(urlStr) ?? (self.cancelled ? nil : self.fetchDataSync(urlStr))
                            dataLock.lock(); datas[j] = d; dataLock.unlock()
                            if d != nil { bumpProgress(1) }
                        }
                    }
                    bg.wait()
                    if self.cancelled { done(.failure(VimeoError.cancelled)); return }
                    let got = datas.compactMap { $0 }
                    guard got.count == batch.count else {
                        let miss = datas.firstIndex(of: nil) ?? 0
                        done(.failure(VimeoError.network("分片 \(start + miss + 1)/\(track.segments.count) 下载失败")))
                        return
                    }
                    do {
                        for d in got { try fh.write(contentsOf: d) }
                    } catch {
                        done(.failure(VimeoError.network("写入临时文件失败：\(error.localizedDescription)")))
                        return
                    }
                    start += batch.count
                }
                done(.success(out))
            }
        }

        let muxQueue = DispatchQueue(label: "com.local.VideoGrab.vimeo.mux")

        func mux(videoURL: URL?, audioURL: URL) {
            guard !cancelled else { onFinish(.failure(VimeoError.cancelled.localizedDescription)); return }
            let ext = quality == .audio ? "mp3" : "mp4"
            let dest = saveDir.appendingPathComponent(sanitize(title) + "." + ext)
            var args = ["-y", "-hide_banner", "-loglevel", "error"]
            if let videoURL {
                args += ["-i", videoURL.path, "-i", audioURL.path, "-c", "copy", "-movflags", "+faststart"]
            } else {
                args += ["-i", audioURL.path, "-vn", "-c:a", "libmp3lame", "-q:a", "0"]
            }
            args.append(dest.path)
            runFFmpeg(ffmpeg, args: args) { [weak self] exitOK, errMsg in
                guard let self else { return }
                try? FileManager.default.removeItem(at: workDir)
                if self.cancelled { return }
                if exitOK {
                    onFinish(.success(dest.lastPathComponent))
                } else {
                    onFinish(.failure(errMsg ?? "Vimeo 封装失败。"))
                }
            }
        }

        // 并行下载视频轨和音轨，都完成后封装
        let group = DispatchGroup()
        var videoURL: URL?
        var audioURL: URL?
        var firstError: Error?

        if let video {
            group.enter()
            downloadTrack(video, name: "video.mp4") { res in
                if case .success(let u) = res { videoURL = u }
                else if case .failure(let e) = res, firstError == nil { firstError = e }
                group.leave()
            }
        }
        if let audio {
            group.enter()
            downloadTrack(audio, name: "audio.mp4") { res in
                if case .success(let u) = res { audioURL = u }
                else if case .failure(let e) = res, firstError == nil { firstError = e }
                group.leave()
            }
        }

        group.notify(queue: muxQueue) {
            if let firstError {
                try? FileManager.default.removeItem(at: workDir)
                if (firstError as? VimeoError) == .cancelled { return }
                onFinish(.failure(firstError.localizedDescription)); return
            }
            guard let audioURL else {
                try? FileManager.default.removeItem(at: workDir)
                onFinish(.failure(VimeoError.noMedia.localizedDescription)); return
            }
            mux(videoURL: videoURL, audioURL: audioURL)
        }
    }

    // MARK: - 工具

    private func fetchDataSync(_ urlString: String) -> Data? {
        guard !cancelled, let u = URL(string: urlString) else { return nil }
        var req = URLRequest(url: u)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://player.vimeo.com/", forHTTPHeaderField: "Referer")
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        session?.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code < 400 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 60)
        return result
    }

    private func runFFmpeg(_ ffmpeg: String, args: [String], done: @escaping (Bool, String?) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = errPipe
        ffmpegProcess = proc
        var tail: [String] = []
        let queue = DispatchQueue(label: "com.local.VideoGrab.vimeo.ffmpeg")
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            if let s = String(data: d, encoding: .utf8), !s.isEmpty {
                queue.async {
                    tail.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
                    if tail.count > 4 { tail.removeFirst() }
                }
            }
        }
        proc.terminationHandler = { [weak self] p in
            let last = queue.sync { tail.last }
            self?.ffmpegProcess = nil
            let ok = p.terminationStatus == 0
            done(ok, ok ? nil : (last ?? "ffmpeg 退出码 \(p.terminationStatus)"))
        }
        do { try proc.run() } catch {
            ffmpegProcess = nil
            done(false, "启动 ffmpeg 失败：\(error.localizedDescription)")
        }
    }

    private func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = s.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "video" : String(cleaned.prefix(120))
    }
}
