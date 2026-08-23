import Foundation

// 微信视频号（weixin.qq.com/sph/xxx、channels.weixin.qq.com）解析。
//
// 视频号没有公开的网页版 / 下载接口：web 端 finder-preview 的 get_feed_info
// 只返回封面、文案等元数据；真正的视频直链 + 解密种子（decodeKey）藏在微信
// 客户端接口 objectDesc.media 里，必须携带微信会话 token 才能拿到，而且视频
// 文件本身是 Isaac64 XOR 加密的，下载后还要解密。所以这里只做「匿名元数据解析」
// —— 识别视频、拿到标题 / 作者 / 封面；下载本身 VideoGrab 不支持。
enum WechatChannelsResolver {
    struct Resolved {
        let title: String
        let author: String
        let coverURL: String
        let exportID: String   // 动态 export id
    }

    enum ResolveError: LocalizedError {
        case notChannels
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notChannels:
                return "无法识别视频号链接（应形如 weixin.qq.com/sph/xxxx）。"
            case .network(let m):
                return "解析视频号失败：\(m)"
            }
        }
    }

    // 强制直连：视频号是国内站，走 Clash 代理会被截断
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
        ]
        cfg.timeoutIntervalForRequest = 25
        return URLSession(configuration: cfg)
    }()

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

    // 从分享链接里取 shortUri（短链 id）：
    //   weixin.qq.com/sph/AgJUW8v3HU
    //   channels.weixin.qq.com/finder-preview/pages/sph?id=AgJUW8v3HU
    static func shortID(from url: String) -> String? {
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return nil }
        if host.contains("weixin.qq.com") {
            let parts = u.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if parts.first == "sph", parts.count >= 2 { return parts[1] }
        }
        if host.contains("channels.weixin.qq.com") {
            if let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
               let id = items.first(where: { $0.name == "id" })?.value,
               !id.isEmpty {
                return id
            }
        }
        return nil
    }

    static func resolve(url: String, completion: @escaping (Result<Resolved, Error>) -> Void) {
        guard let id = shortID(from: url) else {
            completion(.failure(ResolveError.notChannels)); return
        }
        let payload: [String: Any] = ["baseReq": ["generalToken": ""], "shortUri": id]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let endpoint = URL(string: "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info") else {
            completion(.failure(ResolveError.network("无法构造请求"))); return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://channels.weixin.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://channels.weixin.qq.com", forHTTPHeaderField: "Origin")

        session.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(ResolveError.network(err.localizedDescription))); return }
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                completion(.failure(ResolveError.network("HTTP \(code)"))); return
            }
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let feed = d["feedInfo"] as? [String: Any] else {
                completion(.failure(ResolveError.network("响应结构异常"))); return
            }
            let title = (feed["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "视频号视频"
            let author = ((d["authorInfo"] as? [String: Any])?["nickname"] as? String) ?? ""
            let cover = (feed["coverUrl"] as? String) ?? ""
            let exportID = ((d["sceneInfo"] as? [String: Any])?["dynamicExportId"] as? String) ?? ""
            completion(.success(Resolved(title: title, author: author,
                                         coverURL: cover, exportID: exportID)))
        }.resume()
    }
}
