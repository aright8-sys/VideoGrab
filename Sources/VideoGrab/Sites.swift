import Foundation

enum Sites {
    static let cnHosts = ["bilibili.com", "b23.tv", "xinpianchang.com"]
    static let bilibiliHosts = ["bilibili.com", "b23.tv"]

    static let clipboardPattern = #"https?://[^\s'"<>]+"#

    static func isCNHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return cnHosts.contains { h.contains($0) }
    }

    static func isBilibili(_ host: String) -> Bool {
        let h = host.lowercased()
        return bilibiliHosts.contains { h.contains($0) }
    }

    static func firstSupportedURL(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: clipboardPattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let candidate = ns.substring(with: m.range)
            let lower = candidate.lowercased()
            if cnHosts.contains(where: { lower.contains($0) })
                || lower.contains("youtube.com") || lower.contains("youtu.be") {
                return candidate
            }
        }
        return nil
    }
}
