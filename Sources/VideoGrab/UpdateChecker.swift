import Foundation

// 应用更新检查：查询 GitHub Releases 最新版，与本机版本做语义化比较。
// 手动按钮触发，未认证 API 限额（60 次/时/IP）完全够用。
enum UpdateChecker {
    struct Release: Equatable {
        let version: String     // 去掉 v 前缀的版本号
        let pageURL: URL        // Release 网页（跳浏览器兜底）
        let notes: String       // 发布说明（Markdown 原文）
        let zipURL: URL?        // 受信任的 zip 直链；校验失败则为 nil
        let sha256: String?     // 小写 hex；GitHub 未提供则为 nil，此时只允许网页下载
        var canAutoUpdate: Bool { zipURL != nil && sha256 != nil }
    }

    enum CheckResult {
        case upToDate
        case available(Release)
        case failure(String)
    }

    static let repo = "aright8-sys/VideoGrab"
    static let zipName = "VideoGrab.zip"
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    // 本机版本：打包后有 Info.plist；swift run 裸跑没有，按 0.0.0 处理（总会提示有新版）
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 查询

    static func check(completion: @escaping @Sendable (CheckResult) -> Void) {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("VideoGrab/\(currentVersion) (+https://github.com/\(repo))", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: CheckResult
            if let err {
                result = .failure("网络错误：\(err.localizedDescription)")
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
                result = .failure("GitHub 访问受限，请稍后再试。")
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure("GitHub 返回 \(http.statusCode)。")
            } else if let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = parse(obj, current: currentVersion)
            } else {
                result = .failure("响应格式异常。")
            }
            completion(result)
        }.resume()
    }

    /// 解析 GitHub /releases/latest JSON。测试可直接喂字典。
    static func parse(_ obj: [String: Any], current: String) -> CheckResult {
        guard let tag = obj["tag_name"] as? String else { return .failure("响应格式异常。") }
        let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))
        guard compare(version, current) == .orderedDescending else { return .upToDate }
        let page = URL(string: obj["html_url"] as? String ?? "https://github.com/\(repo)/releases/latest")!
        let notes = obj["body"] as? String ?? ""
        var zipURL: URL?
        var sha256: String?
        if let assets = obj["assets"] as? [[String: Any]],
           let asset = assets.first(where: { ($0["name"] as? String) == zipName }) {
            if let raw = asset["browser_download_url"] as? String,
               let url = URL(string: raw), isTrustedZipURL(url) {
                zipURL = url
            }
            sha256 = parseDigest(asset["digest"] as? String)
        }
        return .available(Release(version: version, pageURL: page, notes: notes, zipURL: zipURL, sha256: sha256))
    }

    /// 只接受本仓库、带 tag 的 https GitHub 资产地址，拒绝 latest 浮动链接和环境变量注入。
    static func isTrustedZipURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.host?.lowercased() == "github.com" else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        // /aright8-sys/VideoGrab/releases/download/<tag>/VideoGrab.zip
        guard parts.count == 6,
              parts[0] == "aright8-sys",
              parts[1] == "VideoGrab",
              parts[2] == "releases",
              parts[3] == "download",
              parts[5] == zipName else { return false }
        return !parts[4].isEmpty && parts[4] != "latest"
    }

    /// 接受 `sha256:<hex>` 或裸 64 位 hex。
    static func parseDigest(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let r = s.range(of: "sha256:", options: .caseInsensitive) {
            s = String(s[r.upperBound...])
        }
        s = s.lowercased()
        guard s.count == 64, s.allSatisfy(\.isHexDigit) else { return nil }
        return s
    }

    // MARK: - 版本比较

    /// 按点分数字逐段比较："2.10.0" > "2.9.1"；段数不足补 0；非数字段按字符串比。
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        var pa = a.split(separator: ".").map(String.init)
        var pb = b.split(separator: ".").map(String.init)
        while pa.count < pb.count { pa.append("0") }
        while pb.count < pa.count { pb.append("0") }
        for (x, y) in zip(pa, pb) {
            if let xi = Int(x), let yi = Int(y) {
                if xi != yi { return xi < yi ? .orderedAscending : .orderedDescending }
            } else if x != y {
                return x < y ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
