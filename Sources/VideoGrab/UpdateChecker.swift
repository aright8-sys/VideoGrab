import Foundation

// 应用更新检查：查询 GitHub Releases 最新版，与本机版本做语义化比较。
// 手动按钮触发，未认证 API 限额（60 次/时/IP）完全够用。
enum UpdateChecker {
    struct Release {
        let version: String     // 去掉 v 前缀的版本号
        let pageURL: URL        // Release 网页（跳浏览器下载）
        let notes: String       // 发布说明（Markdown 原文）
    }

    enum CheckResult {
        case upToDate
        case available(Release)
        case failure(String)
    }

    static let repo = "aright8-sys/VideoGrab"
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    // 本机版本：打包后有 Info.plist；swift run 裸跑没有，按 0.0.0 处理（总会提示有新版）
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 查询

    static func check(completion: @escaping @Sendable (CheckResult) -> Void) {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: CheckResult
            if let err {
                result = .failure("网络错误：\(err.localizedDescription)")
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
                // GitHub 匿名限额耗尽或被限流
                result = .failure("GitHub 访问受限，请稍后再试。")
            } else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure("GitHub 返回 \(http.statusCode)。")
            } else if let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String {
                let version = tag.drop(while: { $0 == "v" || $0 == "V" })
                if compare(String(version), currentVersion) == .orderedDescending,
                   let page = URL(string: obj["html_url"] as? String ?? "https://github.com/\(repo)/releases/latest") {
                    let notes = obj["body"] as? String ?? ""
                    result = .available(Release(version: String(version), pageURL: page, notes: notes))
                } else {
                    result = .upToDate
                }
            } else {
                result = .failure("响应格式异常。")
            }
            completion(result)
        }.resume()
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
