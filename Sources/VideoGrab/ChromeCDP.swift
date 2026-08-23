import Foundation
import Darwin

// 用本机 Chrome 的无头模式 + CDP 过 Cloudflare Turnstile。
//
// Vimeo 现在对匿名请求：watch 页是 Turnstile 挑战、匿名 OAuth 端点 401、
// player 配置接口 403/401，yt-dlp 的 Vimeo 提取器已坏。无头 Chrome 加上
// 反自动化规避（去掉 AutomationControlled、覆盖 navigator.webdriver）后
// 能正常加载播放器，从而在 Network 事件里拿到带签名的 DASH playlist.json 地址。
final class ChromeCDP {
    enum ChromeError: LocalizedError {
        case notInstalled
        case launchFailed(String)
        case cdpUnavailable
        case ws(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:       return "未找到 Google Chrome，Vimeo 下载需要本机 Chrome。"
            case .launchFailed(let m): return "启动 Chrome 失败：\(m)"
            case .cdpUnavailable:     return "无法连接 Chrome 调试接口。"
            case .ws(let m):          return "Chrome 调试连接失败：\(m)"
            }
        }
    }

    private static let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

    private let process: Process
    private let port: Int
    private let profileDir: URL
    private var urlSession: URLSession?
    private var ws: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "com.local.VideoGrab.chrome.cdp")
    private var nextID = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var eventHandler: ((String, [String: Any]) -> Void)?
    private var stopped = false

    init() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.chromePath) else {
            throw ChromeError.notInstalled
        }
        port = Self.freePort()
        profileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-chrome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.chromePath)
        p.arguments = [
            "--headless=new",
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profileDir.path)",
            "--no-first-run", "--no-default-browser-check",
            "--disable-blink-features=AutomationControlled",
            "--window-size=1920,1080", "--lang=en-US,en",
            "--disable-background-networking", "--disable-component-update", "--disable-sync",
            "--metrics-recording-only", "--safebrowsing-disable-auto-update",
            "--user-agent=\(Self.ua)",
            "about:blank"
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        process = p
    }

    deinit { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        urlSession = nil
        queue.async { self.pending.removeAll() }
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: profileDir)
    }

    // 启动 Chrome、等 CDP 就绪、打开空白标签页并连上调试通道；导航由调用方在 Network.enable 后发起
    func launch(completion: @escaping (Error?) -> Void) {
        do { try process.run() } catch {
            completion(ChromeError.launchFailed(error.localizedDescription)); return
        }
        pollUntilReady { [weak self] readyErr in
            guard let self else { return }
            if let readyErr { completion(readyErr); return }
            self.newTab(url: "about:blank") { wsURL, err in
                if let err { completion(err); return }
                guard let wsURL else { completion(ChromeError.cdpUnavailable); return }
                self.connect(wsURL: wsURL, completion: completion)
            }
        }
    }

    // MARK: - HTTP 控制面

    private func pollUntilReady(deadline: Date = Date().addingTimeInterval(20), done: @escaping (Error?) -> Void) {
        if Date() > deadline { done(ChromeError.cdpUnavailable); return }
        getJSON("http://127.0.0.1:\(port)/json/version") { [weak self] _, status in
            guard let self else { return }
            if status == 200 { done(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                self.pollUntilReady(deadline: deadline, done: done)
            }
        }
    }

    private func newTab(url: String, completion: @escaping (URL?, Error?) -> Void) {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url
        guard let target = URL(string: "http://127.0.0.1:\(port)/json/new?\(encoded)") else {
            completion(nil, ChromeError.cdpUnavailable); return
        }
        var req = URLRequest(url: target)
        req.httpMethod = "PUT"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(nil, ChromeError.ws(err.localizedDescription)); return }
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let wsStr = obj["webSocketDebuggerUrl"] as? String,
                  let wsURL = URL(string: wsStr) else {
                completion(nil, ChromeError.cdpUnavailable); return
            }
            completion(wsURL, nil)
        }.resume()
    }

    private func getJSON(_ urlString: String, completion: @escaping (Data?, Int) -> Void) {
        guard let u = URL(string: urlString) else { completion(nil, -1); return }
        URLSession.shared.dataTask(with: u) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            completion(data, code)
        }.resume()
    }

    // MARK: - WebSocket CDP

    private func connect(wsURL: URL, completion: @escaping (Error?) -> Void) {
        let s = URLSession(configuration: .ephemeral)
        urlSession = s
        let task = s.webSocketTask(with: wsURL)
        ws = task
        task.resume()
        receive()
        completion(nil)
    }

    private func receive() {
        ws?.receive { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receive()
            case .failure(let err):
                if (err as NSError).code != NSURLErrorCancelled {
                    self.queue.async { self.failAll(ChromeError.ws(err.localizedDescription)) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        queue.async {
            if let id = obj["id"] as? Int, let cb = self.pending.removeValue(forKey: id) {
                if let err = obj["error"] as? [String: Any] {
                    let msg = (err["message"] as? String) ?? "CDP 错误"
                    cb(.failure(ChromeError.ws(msg)))
                } else {
                    cb(.success(obj))
                }
            } else if let method = obj["method"] as? String {
                self.eventHandler?(method, obj["params"] as? [String: Any] ?? [:])
            }
        }
    }

    private func failAll(_ error: Error) {
        let cbs = Array(pending.values)
        pending.removeAll()
        cbs.forEach { $0(.failure(error)) }
    }

    func send(_ method: String, params: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async {
            guard !self.stopped, let ws = self.ws else {
                completion(.failure(ChromeError.ws("Chrome 已关闭"))); return
            }
            let id = self.nextID
            self.nextID += 1
            self.pending[id] = completion
            let msg: [String: Any] = ["id": id, "method": method, "params": params]
            guard let data = try? JSONSerialization.data(withJSONObject: msg),
                  let text = String(data: data, encoding: .utf8) else {
                self.pending.removeValue(forKey: id)
                completion(.failure(ChromeError.ws("无法构造 CDP 请求"))); return
            }
            ws.send(.string(text)) { err in
                if let err {
                    self.queue.async {
                        self.pending.removeValue(forKey: id)
                        completion(.failure(ChromeError.ws(err.localizedDescription)))
                    }
                }
            }
        }
    }

    func onEvent(_ handler: @escaping (String, [String: Any]) -> Void) {
        queue.async { self.eventHandler = handler }
    }

    // MARK: - 端口

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 9222 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 9222 }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = withUnsafeMutablePointer(to: &got) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard r == 0 else { return 9222 }
        return Int(got.sin_port.bigEndian)
    }
}
