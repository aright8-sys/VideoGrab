import Foundation

enum Sites {
    static let cnHosts = ["bilibili.com", "b23.tv", "xinpianchang.com",
                          "xiaohongshu.com", "xhslink.com", "xhs.cn",
                          "weixin.qq.com", "channels.weixin.qq.com"]
    static let bilibiliHosts = ["bilibili.com", "b23.tv"]
    static let xiaohongshuHosts = ["xiaohongshu.com", "xhslink.com", "xhs.cn"]
    static let instagramHosts = ["instagram.com", "instagr.am"]
    static let pinterestHosts = ["pinterest.com", "pin.it"]
    static let vimeoHosts = ["vimeo.com"]
    static let wechatChannelsHosts = ["weixin.qq.com", "channels.weixin.qq.com"]

    // 剪贴板取链接的正则：只收 RFC 3986 的合法 URL 字符（ASCII）。
    // 不能用「只排除空白」的宽匹配——聊天软件里「链接后紧跟中文、中间无空格」
    // 会把后面整句话吞进 URL 导致下载失败；从第一个非法字符截断才稳。
    static let clipboardPattern = #"https?://[A-Za-z0-9\-._~:/?#@!$&*+,;=%()\[\]]+"#

    // 域名后缀匹配：host 等于该域名或为其子域名才命中。
    // 不能用 contains——「bilibili.com.evil.com」这类假域名也会包含真域名而被误判。
    private static func matches(_ host: String, _ domains: [String]) -> Bool {
        let h = host.lowercased()
        return domains.contains { h == $0 || h.hasSuffix(".\($0)") }
    }

    static func isCNHost(_ host: String) -> Bool { matches(host, cnHosts) }

    static func isBilibili(_ host: String) -> Bool { matches(host, bilibiliHosts) }

    static func isXiaohongshu(_ host: String) -> Bool { matches(host, xiaohongshuHosts) }

    static func isInstagram(_ host: String) -> Bool { matches(host, instagramHosts) }

    static func isPinterest(_ host: String) -> Bool { matches(host, pinterestHosts) }

    static func isVimeo(_ host: String) -> Bool { matches(host, vimeoHosts) }

    static func isYouTube(_ host: String) -> Bool { matches(host, ["youtube.com", "youtu.be"]) }

    static func isWechatChannels(_ host: String) -> Bool { matches(host, wechatChannelsHosts) }

    // 需要读取浏览器 Cookie 才能稳定下载的站点（登录态/风控）
    static func needsCookies(_ host: String) -> Bool {
        isBilibili(host) || isXiaohongshu(host) || isInstagram(host)
    }

    // 提取文本里全部 http(s) 链接：去重保序、剪掉句读尾巴。批量队列下载的入口。
    static func allURLs(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: clipboardPattern) else { return [] }
        let ns = text as NSString
        let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // 中文输入法/聊天软件常在链接后粘句读（「https://vimeo.com/123。」）。
        // 这些字符不可能是合法结尾，直接剪掉；括号除外（维基类 URL 以 ) 结尾是合法的）。
        let junk = CharacterSet(charactersIn: "。，、；！？：）》」』】“”‘’…·,.!?;:")
        var seen = Set<String>()
        var urls: [String] = []
        for m in found {
            var url = ns.substring(with: m.range)
            while let last = url.unicodeScalars.last, junk.contains(last) {
                url.removeLast()
            }
            if !url.isEmpty, seen.insert(url).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    // 剪贴板取第一个 http(s) 链接——不再按站点白名单过滤，任何网址都自动预填。
    static func firstURL(in text: String) -> String? {
        allURLs(in: text).first
    }
}
