import Foundation

// Pinterest 原生视频（pinimg CDN）走 yt-dlp 通用路径即可；但有些 pin 是 Vimeo
// 视频的「视频 pin」——页面里只有封面图 + vimeo.com 外链，没有原生 mp4，
// yt-dlp 会转到 Vimeo 提取器然后 401。这里先抓 pin 页判断来源：
// 是 Vimeo 就明确提示「暂不支持」，否则走 yt-dlp。（Vimeo 视频现受 DRM 加密，已不再支持下载。）
enum PinterestResolver {
    enum Outcome {
        case native
        case vimeo(String)
    }

    enum ResolveError: LocalizedError {
        case network(String)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .network(let m): return "解析 Pinterest 失败：\(m)"
            case .invalidURL:     return "无法识别该 Pinterest 链接。"
            }
        }
    }

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    static func resolve(url: String, completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard let u = URL(string: url) else {
            completion(.failure(ResolveError.invalidURL)); return
        }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(ResolveError.network(err.localizedDescription))); return }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                completion(.failure(ResolveError.network("HTTP \(code)"))); return
            }
            guard let data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(ResolveError.network("无响应数据"))); return
            }
            if let id = vimeoVideoID(in: html) {
                completion(.success(.vimeo("https://vimeo.com/\(id)")))
            } else {
                completion(.success(.native))
            }
        }.resume()
    }

    // pin 页里 Vimeo 来源以 vimeo.com/video/{id} 或 vimeo.com/{id} 出现；
    // 只认纯数字 id，避免误匹配 vimeo.com 首页等非视频路径。
    static func vimeoVideoID(in html: String) -> String? {
        let patterns = [#"vimeo\.com/video/(\d{4,})"#, #"vimeo\.com/(\d{4,})"#]
        let ns = html as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            if let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 2 {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }
}
