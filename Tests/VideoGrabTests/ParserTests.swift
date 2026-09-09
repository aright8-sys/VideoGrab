import XCTest
@testable import VideoGrab

// 站点改版最容易坏的就是这些纯函数解析器——这里全部用真实样例钉住行为。
final class ParserTests: XCTestCase {

    // MARK: - 站点域名匹配（后缀精确，防伪装域名）

    func testDomainSuffixMatching() {
        XCTAssertTrue(Sites.isVimeo("vimeo.com"), "裸域名应命中")
        XCTAssertTrue(Sites.isVimeo("player.vimeo.com"), "子域名应命中")
        XCTAssertFalse(Sites.isVimeo("vimeo.com.evil.com"), "假后缀域名不得命中")
        XCTAssertTrue(Sites.isBilibili("www.bilibili.com"))
        XCTAssertTrue(Sites.isBilibili("b23.tv"), "短链应命中")
        XCTAssertFalse(Sites.isBilibili("bilibili.com.evil.com"), "假后缀域名不得命中（会被强制直连）")
        XCTAssertFalse(Sites.isBilibili("evil-bilibili.com"), "前缀伪装不得命中（旧 contains 实现的缺陷）")
        XCTAssertTrue(Sites.isCNHost("www.xiaohongshu.com"), "国内站识别→直连")
        XCTAssertFalse(Sites.isCNHost("youtube.com"))
    }

    func testNeedsCookies() {
        XCTAssertTrue(Sites.needsCookies("www.bilibili.com"))
        XCTAssertTrue(Sites.needsCookies("xiaohongshu.com"))
        XCTAssertTrue(Sites.needsCookies("instagram.com"))
        XCTAssertFalse(Sites.needsCookies("vimeo.com"))
        XCTAssertFalse(Sites.needsCookies("youtube.com"))
    }

    // MARK: - 剪贴板链接识别

    func testFirstURLCutsCJKTextGluedToLink() {
        XCTAssertEqual(Sites.firstURL(in: "看看这个 https://vimeo.com/839105735。很好看"),
                       "https://vimeo.com/839105735", "链接后紧跟中文句号+文字应截断")
        XCTAssertEqual(Sites.firstURL(in: "链接https://www.bilibili.com/video/BV1xx411c7mD这是标题"),
                       "https://www.bilibili.com/video/BV1xx411c7mD", "无空格粘连也应截断")
    }

    func testFirstURLKeepsLegalPunctuation() {
        XCTAssertEqual(Sites.firstURL(in: "see https://en.wikipedia.org/wiki/Foo_(bar) here"),
                       "https://en.wikipedia.org/wiki/Foo_(bar)", "括号是合法 URL 结尾，保留")
        XCTAssertEqual(Sites.firstURL(in: "https://x.com/a_b?s=20"), "https://x.com/a_b?s=20", "查询参数不动")
        XCTAssertEqual(Sites.firstURL(in: "end https://vimeo.com/123."),
                       "https://vimeo.com/123", "英文句点结尾剪掉")
    }

    func testFirstURLPicksFirstAndRejectsNone() {
        XCTAssertEqual(Sites.firstURL(in: "a https://a.com/1 b https://b.com/2"),
                       "https://a.com/1", "取第一个")
        XCTAssertNil(Sites.firstURL(in: "没有链接的文本"))
    }

    func testAllURLsExtractsDedupesAndKeepsOrder() {
        let text = """
        https://vimeo.com/1
        看看 https://youtu.be/abc 还有 https://vimeo.com/1
        https://www.bilibili.com/video/BV1xx411c7mD。
        """
        XCTAssertEqual(Sites.allURLs(in: text), [
            "https://vimeo.com/1",
            "https://youtu.be/abc",
            "https://www.bilibili.com/video/BV1xx411c7mD",
        ])
    }

    // MARK: - 版本比较与更新包校验

    func testCompareVersions() {
        XCTAssertEqual(UpdateChecker.compare("2.10.0", "2.9.1"), .orderedDescending)
        XCTAssertEqual(UpdateChecker.compare("2.3", "2.3.0"), .orderedSame)
        XCTAssertEqual(UpdateChecker.compare("2.2.9", "2.3.0"), .orderedAscending)
        XCTAssertEqual(UpdateChecker.compare("2.3.1", "2.3.0"), .orderedDescending)
    }

    func testParseDigestAndTrustedZipURL() {
        XCTAssertEqual(UpdateChecker.parseDigest("sha256:8a10f252e4e6d0384a69dd911d3206ae4fbb1288a478a606f48d90e2d3c1b87a"),
                       "8a10f252e4e6d0384a69dd911d3206ae4fbb1288a478a606f48d90e2d3c1b87a")
        XCTAssertNil(UpdateChecker.parseDigest("md5:abc"), "非 sha256 拒绝")
        XCTAssertNil(UpdateChecker.parseDigest("sha256:xyz"), "非 hex 拒绝")

        let ok = URL(string: "https://github.com/aright8-sys/VideoGrab/releases/download/v2.4.0/VideoGrab.zip")!
        XCTAssertTrue(UpdateChecker.isTrustedZipURL(ok))
        XCTAssertFalse(UpdateChecker.isTrustedZipURL(URL(string: "https://github.com/aright8-sys/VideoGrab/releases/latest/download/VideoGrab.zip")!))
        XCTAssertFalse(UpdateChecker.isTrustedZipURL(URL(string: "https://evil.example/VideoGrab.zip")!))
        XCTAssertFalse(UpdateChecker.isTrustedZipURL(URL(string: "http://github.com/aright8-sys/VideoGrab/releases/download/v2.4.0/VideoGrab.zip")!))
    }

    func testParseReleaseJSONRequiresHigherVersionAndPinnedAsset() {
        let json: [String: Any] = [
            "tag_name": "v9.9.9",
            "html_url": "https://github.com/aright8-sys/VideoGrab/releases/tag/v9.9.9",
            "body": "notes",
            "assets": [[
                "name": "VideoGrab.zip",
                "browser_download_url": "https://github.com/aright8-sys/VideoGrab/releases/download/v9.9.9/VideoGrab.zip",
                "digest": "sha256:8a10f252e4e6d0384a69dd911d3206ae4fbb1288a478a606f48d90e2d3c1b87a",
            ]],
        ]
        if case .available(let r) = UpdateChecker.parse(json, current: "2.3.0") {
            XCTAssertEqual(r.version, "9.9.9")
            XCTAssertTrue(r.canAutoUpdate)
            XCTAssertEqual(r.sha256, "8a10f252e4e6d0384a69dd911d3206ae4fbb1288a478a606f48d90e2d3c1b87a")
        } else {
            XCTFail("应解析为有新版本")
        }

        if case .upToDate = UpdateChecker.parse(json, current: "9.9.9") {} else {
            XCTFail("同版本应为已是最新")
        }

        var noDigest = json
        noDigest["assets"] = [[
            "name": "VideoGrab.zip",
            "browser_download_url": "https://github.com/aright8-sys/VideoGrab/releases/download/v9.9.9/VideoGrab.zip",
        ]]
        if case .available(let r) = UpdateChecker.parse(noDigest, current: "2.3.0") {
            XCTAssertFalse(r.canAutoUpdate, "没有 digest 只能走网页下载")
        } else {
            XCTFail("无 digest 仍应提示有新版本")
        }
    }

    // MARK: - yt-dlp 输出解析

    func testParsePercent() throws {
        XCTAssertEqual(try XCTUnwrap(Downloader.parsePercent("[download]   5.2% of   19.31MiB at  1.20MiB/s")),
                       0.052, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Downloader.parsePercent("[download] 100.0% of 512.00MiB")),
                       1.0, accuracy: 1e-9)
        XCTAssertNil(Downloader.parsePercent("[info] Downloading video thumbnail 1 of 3"), "非下载行不误报")
        XCTAssertNil(Downloader.parsePercent(""), "空行安全")
    }

    func testParseDestination() {
        XCTAssertEqual(Downloader.parseDestination(#"[download] Destination: /Users/x/Movies/视频 名.mp4"#),
                       "视频 名.mp4", "含空格/中文文件名完整保留到末段")
        XCTAssertEqual(Downloader.parseDestination(#"[Merger] Merging formats into "/tmp/a b.mp4""#),
                       "a b.mp4", "Merger 行取引号内路径末段")
        XCTAssertNil(Downloader.parseDestination("[download] Got error: HTTP Error 403"), "非目标行返回 nil")
    }

    // MARK: - 新片场解析

    func testXinpianchangArticleID() {
        XCTAssertEqual(XinpianchangResolver.articleID(from: "https://www.xinpianchang.com/a13456789?from=user"),
                       "13456789", "从 /aN 路径取数字 id")
        XCTAssertNil(XinpianchangResolver.articleID(from: "https://www.xinpianchang.com/videos"), "非文章页 nil")
    }

    func testXinpianchangExtractVidAppKeyPrefersMainVideoBlock() {
        let html = #"{"video":{"isNewModServer":true,"appKey":"k123","type":1,"vid":"abc123DEF"},"others":[{"video":{"vid":"zzz","appKey":"kk"}}]}"#
        let got = XinpianchangResolver.extractVidAppKey(html)
        XCTAssertEqual(got?.vid, "abc123DEF", "只认主作品 video 块，不吃 others 推荐位")
        XCTAssertEqual(got?.appKey, "k123")
        XCTAssertNil(XinpianchangResolver.extractVidAppKey("<html>无视频数据</html>"))
    }

    func testXinpianchangPickMP4RespectsQualityCapAndEmptyURL() {
        let json = """
        {"data":{"title":"测试标题","resource":{"progressive":[
            {"height":"1080","url":""},
            {"height":"720","url":"https://cdn/u720.mp4"},
            {"height":480,"url":"https://cdn/u480.mp4"}]}}}
        """
        let data = Data(json.utf8)
        XCTAssertEqual(XinpianchangResolver.pickMP4(data, quality: .p720)?.mp4,
                       "https://cdn/u720.mp4", "会员专享(url 空)的高档被排除，取 ≤720 的最高档")
        XCTAssertEqual(XinpianchangResolver.pickMP4(data, quality: .best)?.mp4,
                       "https://cdn/u720.mp4", "最高画质也只选有直链的最高档")
        XCTAssertEqual(XinpianchangResolver.pickMP4(data, quality: .p1080)?.title, "测试标题")
        XCTAssertNil(XinpianchangResolver.pickMP4(Data("{}".utf8), quality: .best), "结构不符 nil")
    }

    // MARK: - 微信视频号短链

    func testWechatShortID() {
        XCTAssertEqual(WechatChannelsResolver.shortID(from: "https://weixin.qq.com/sph/AgJUW8v3HU"),
                       "AgJUW8v3HU")
        XCTAssertEqual(WechatChannelsResolver.shortID(from: "https://channels.weixin.qq.com/finder-preview/pages/sph?id=AgJUW8v3HU"),
                       "AgJUW8v3HU", "?id= 形式")
        XCTAssertNil(WechatChannelsResolver.shortID(from: "https://example.com/sph/x"), "非微信域名 nil")
    }

    // MARK: - Pinterest → Vimeo 判定

    func testPinterestVimeoIDExtraction() {
        XCTAssertEqual(PinterestResolver.vimeoVideoID(in: #"src="https://vimeo.com/video/987654321""#),
                       "987654321", "/video/{id} 形式")
        XCTAssertEqual(PinterestResolver.vimeoVideoID(in: "href=https://vimeo.com/98765432"),
                       "98765432", "裸 {id} 形式")
        XCTAssertNil(PinterestResolver.vimeoVideoID(in: "visit https://vimeo.com for more"),
                     "纯首页不是视频 pin")
    }
}
