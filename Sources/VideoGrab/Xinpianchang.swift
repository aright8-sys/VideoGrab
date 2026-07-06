import Foundation

// 新片场文章页(www.xinpianchang.com/aXXXX)被网宿(Wangsu) FEC 的 JS 反爬挡住，yt-dlp 直接抓 HTML
// 只会拿到「安全检测中」挑战页(403/406)，且 cookie/header/TLS 指纹/无头浏览器都过不去。
//
// 绕开办法：移动端分享页 app.xinpianchang.com/article/{id} 不在 WAF 后面，直接返回含 vid+appKey
// 的 JSON；而媒体接口 mod-api.xinpianchang.com 本就开放。于是纯 HTTP 两步拿到直链 mp4，
// 再交给 yt-dlp 下载，全程不需要浏览器。
enum XinpianchangResolver {
    struct Resolved { let mp4: String; let title: String }
    enum ResolveError: LocalizedError {
        case notArticle, noVid, noFormat, network(String)
        var errorDescription: String? {
            switch self {
            case .notArticle:     return "无法识别新片场作品链接（应形如 xinpianchang.com/a1234567）。"
            case .noVid:          return "解析新片场作品失败，页面结构可能已变化。"
            case .noFormat:       return "未找到可下载的画质（可能是会员专享视频）。"
            case .network(let m): return "解析新片场失败：\(m)"
            }
        }
    }

    static func isXinpianchang(_ host: String) -> Bool {
        host.lowercased().contains("xinpianchang.com")
    }

    // 移动端 UA，走 app 分享页那套接口
    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    // 强制直连：新片场是国内站，走 Clash 代理会被截断
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
        ]
        cfg.timeoutIntervalForRequest = 25
        return URLSession(configuration: cfg)
    }()

    static func resolve(url: String, quality: Quality,
                        completion: @escaping (Result<Resolved, Error>) -> Void) {
        guard let id = articleID(from: url) else {
            completion(.failure(ResolveError.notArticle)); return
        }
        // 1) 分享页拿 vid + appKey
        request("https://app.xinpianchang.com/article/\(id)") { data, errMsg in
            if let errMsg { completion(.failure(ResolveError.network(errMsg))); return }
            guard let data, let html = String(data: data, encoding: .utf8),
                  let (vid, appKey) = extractVidAppKey(html) else {
                completion(.failure(ResolveError.noVid)); return
            }
            // 2) mod-api 拿直链 mp4
            let api = "https://mod-api.xinpianchang.com/mod/api/v2/media/\(vid)?appKey=\(appKey)"
            request(api) { mediaData, errMsg2 in
                if let errMsg2 { completion(.failure(ResolveError.network(errMsg2))); return }
                guard let mediaData, let picked = pickMP4(mediaData, quality: quality) else {
                    completion(.failure(ResolveError.noFormat)); return
                }
                completion(.success(picked))
            }
        }
    }

    // MARK: - 解析

    // 从 .../aXXXXXXX 里取数字 id
    static func articleID(from url: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"/a(\d{4,})"#) else { return nil }
        let ns = url as NSString
        guard let m = re.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // 主作品对象形如 "video":{"isNewModServer":true,"appKey":"xx","type":1,"vid":"yy",...}
    // 推荐视频在 "others" 里，别混：只在 "video":{...} 这个块内取
    private static func extractVidAppKey(_ html: String) -> (vid: String, appKey: String)? {
        let ns = html as NSString
        guard let blockRe = try? NSRegularExpression(pattern: #""video":\{([^}]*)\}"#),
              let bm = blockRe.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              bm.numberOfRanges >= 2 else { return nil }
        let block = ns.substring(with: bm.range(at: 1))
        guard let vid = capture(#""vid":"([A-Za-z0-9]+)""#, in: block),
              let appKey = capture(#""appKey":"([A-Za-z0-9]+)""#, in: block) else { return nil }
        return (vid, appKey)
    }

    // 服务端已按 height 分档；4k/1080p 常为会员专享(url 为空)，只选有直链、不超过所选画质的最高档
    private static func pickMP4(_ data: Data, quality: Quality) -> Resolved? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let res = d["resource"] as? [String: Any],
              let prog = res["progressive"] as? [[String: Any]] else { return nil }
        let cap: Int
        switch quality {
        case .p720:  cap = 720
        case .p1080: cap = 1080
        case .best, .audio: cap = .max   // 音频也先取最高画质，再由 yt-dlp 抽音轨
        }
        let usable = prog.compactMap { p -> (Int, String)? in
            guard let url = p["url"] as? String, !url.isEmpty else { return nil }
            let h = (p["height"] as? Int) ?? Int((p["height"] as? String) ?? "") ?? 0
            return h <= cap ? (h, url) : nil
        }
        guard let best = usable.max(by: { $0.0 < $1.0 }) else { return nil }
        let title = (d["title"] as? String) ?? "视频"
        return Resolved(mp4: best.1, title: title)
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // 回调：成功给 data、失败给错误串（二选一）
    private static func request(_ urlString: String,
                                done: @escaping (Data?, String?) -> Void) {
        guard let u = URL(string: urlString) else { done(nil, "链接无效"); return }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.xinpianchang.com/", forHTTPHeaderField: "Referer")
        session.dataTask(with: req) { data, resp, err in
            if let err { done(nil, err.localizedDescription); return }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                done(nil, "HTTP \(code)"); return
            }
            guard let data else { done(nil, "无响应数据"); return }
            done(data, nil)
        }.resume()
    }
}
