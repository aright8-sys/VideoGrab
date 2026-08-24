import Foundation
import CryptoKit

// 应用自更新：下载 GitHub Release zip → SHA-256 校验 → 解压校验 Bundle → 原位替换 → 重启。
// 无开发者证书，安全性靠「只接受本仓库 pinned 资产 + GitHub 提供的 digest」；
// 解压后核对 Bundle ID 与版本号必须严格高于当前。替换采用「旧包改名备份 + 新包顶位」，失败回滚。
final class SelfUpdater: NSObject, URLSessionDownloadDelegate {
    static let shared = SelfUpdater()

    enum Event {
        case progress(Double)      // 0...1
        case installing
        case failed(String)
        case cancelled
    }

    private var session: URLSession!
    private var onEvent: ((Event) -> Void)?
    private var stagingDir: URL?
    private var task: URLSessionDownloadTask?
    private var expectedSHA256: String?
    private var expectedVersion: String?
    private var cancelled = false
    private let workQueue = DispatchQueue(label: "app.videograb.updater", qos: .userInitiated)
    private let lock = NSLock()

    private static let maxZipBytes: Int64 = 300_000_000

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func downloadAndInstall(zipURL: URL, sha256: String, version: String, onEvent: @escaping (Event) -> Void) {
        lock.lock()
        let busy = task != nil || stagingDir != nil
        lock.unlock()
        guard !busy else { return }
        guard UpdateChecker.isTrustedZipURL(zipURL) else {
            onEvent(.failed("更新地址不受信任。"))
            return
        }
        guard UpdateChecker.parseDigest(sha256) != nil else {
            onEvent(.failed("更新包缺少有效校验和。"))
            return
        }

        cancelled = false
        self.onEvent = onEvent
        expectedSHA256 = sha256.lowercased()
        expectedVersion = version

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoGrab-update-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            post(.failed("无法创建临时目录：\(error.localizedDescription)"))
            return
        }
        stagingDir = staging
        var req = URLRequest(url: zipURL, timeoutInterval: 120)
        req.setValue("VideoGrab/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        let t = session.downloadTask(with: req)
        task = t
        t.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
        cleanupStaging()
        post(.cancelled)
        reset()
    }

    /// 启动时清理上次更新留下的旧版本备份（VideoGrab.old-*.app）
    static func cleanupOldBundles() {
        let current = Bundle.main.bundleURL
        let dir = current.deletingLastPathComponent()
        let prefix = current.deletingPathExtension().lastPathComponent + ".old-"
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(prefix) && item.pathExtension == "app" {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > Self.maxZipBytes || totalBytesWritten > Self.maxZipBytes {
            cancel()
            post(.failed("更新包过大，已中止。"))
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        post(.progress(progress))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        let stop = cancelled
        let staging = stagingDir
        let wantHash = expectedSHA256
        let wantVersion = expectedVersion
        lock.unlock()
        if stop { return }

        let fm = FileManager.default
        do {
            guard let staging, let wantHash, let wantVersion else { throw fail("内部错误：临时目录丢失") }
            if let expected = downloadTask.response?.expectedContentLength, expected > Self.maxZipBytes {
                throw fail("更新包过大，已中止。")
            }
            let zip = staging.appendingPathComponent("VideoGrab.zip")
            if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
            try fm.moveItem(at: location, to: zip)
            let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
            guard size > 0, size <= Self.maxZipBytes else { throw fail("更新包大小异常") }

            workQueue.async { [weak self] in
                self?.install(zip: zip, staging: staging, wantHash: wantHash, wantVersion: wantVersion)
            }
        } catch let failure as Failure {
            cleanupStaging()
            reset()
            post(.failed(failure.message))
        } catch {
            cleanupStaging()
            reset()
            post(.failed("更新失败：\(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let stop = cancelled
        lock.unlock()
        cleanupStaging()
        reset()
        if stop { return }   // cancel() 已发 cancelled
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        post(.failed("下载失败：\(error.localizedDescription)"))
    }

    // MARK: - 校验与安装

    private func install(zip: URL, staging: URL, wantHash: String, wantVersion: String) {
        lock.lock()
        let stop = cancelled
        lock.unlock()
        if stop { return }

        let fm = FileManager.default
        do {
            let hex = try sha256Hex(of: zip)
            guard hex == wantHash else { throw fail("更新包校验和不匹配，已拒绝安装") }

            let payload = staging.appendingPathComponent("payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, payload.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw fail("更新包解压失败") }

            let newApp = try locateApp(in: payload)
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let newVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  !newVersion.isEmpty else {
                throw fail("更新包校验失败（缺少有效的 VideoGrab.app）")
            }
            guard UpdateChecker.compare(newVersion, UpdateChecker.currentVersion) == .orderedDescending else {
                throw fail("服务器版本 (\(newVersion)) 不高于当前版本")
            }
            guard newVersion == wantVersion || UpdateChecker.compare(newVersion, wantVersion) == .orderedSame else {
                throw fail("更新包版本 (\(newVersion)) 与发布版本不符")
            }

            lock.lock()
            let stop2 = cancelled
            lock.unlock()
            if stop2 { return }

            // 校验通过后再处理隔离属性：无公证证书时，不清除 quarantine 则无法自动拉起新实例。
            // 哈希 + Bundle ID + 版本已在前面核对。随后按构建脚本同样做一次 ad-hoc 签名。
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
            try? xattr.run()
            xattr.waitUntilExit()

            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--deep", "--sign", "-", newApp.path]
            try? sign.run()
            sign.waitUntilExit()

            post(.installing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.replaceAndRelaunch(newApp: newApp)
            }
        } catch let failure as Failure {
            cleanupStaging()
            reset()
            post(.failed(failure.message))
        } catch {
            cleanupStaging()
            reset()
            post(.failed("更新失败：\(error.localizedDescription)"))
        }
    }

    private func locateApp(in payload: URL) throws -> URL {
        let fm = FileManager.default
        let direct = payload.appendingPathComponent("VideoGrab.app")
        let candidate: URL
        if fm.fileExists(atPath: direct.path) {
            candidate = direct
        } else {
            let extras = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            guard let nested = extras.first(where: {
                $0.lastPathComponent == "VideoGrab.app" ||
                fm.fileExists(atPath: $0.appendingPathComponent("VideoGrab.app").path)
            }) else { throw fail("更新包内找不到 VideoGrab.app") }
            candidate = nested.lastPathComponent == "VideoGrab.app" ? nested : nested.appendingPathComponent("VideoGrab.app")
        }
        let payloadStd = payload.standardizedFileURL.path
        let appStd = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard appStd.hasPrefix(payloadStd + "/") else { throw fail("更新包路径异常，已拒绝安装") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue else {
            throw fail("更新包不是有效的应用包")
        }
        if let dest = try? fm.destinationOfSymbolicLink(atPath: candidate.path), !dest.isEmpty {
            throw fail("更新包不能是符号链接")
        }
        return candidate
    }

    // MARK: - 替换与重启

    private func replaceAndRelaunch(newApp: URL) {
        lock.lock()
        let stop = cancelled
        lock.unlock()
        if stop { return }

        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let dir = current.deletingLastPathComponent()
        let baseName = current.deletingPathExtension().lastPathComponent
        let backup = dir.appendingPathComponent("\(baseName).old-\(UUID().uuidString).app")
        do {
            try fm.moveItem(at: current, to: backup)
            do {
                try fm.moveItem(at: newApp, to: current)
            } catch {
                try? fm.moveItem(at: backup, to: current)
                throw error
            }
        } catch {
            cleanupStaging()
            reset()
            post(.failed("替换应用失败：\(error.localizedDescription)"))
            return
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [current.path]
        do {
            try open.run()
            open.waitUntilExit()
            guard open.terminationStatus == 0 else {
                throw fail("LaunchServices 返回 \(open.terminationStatus)")
            }
            cleanupStaging()
            exit(0)
        } catch {
            try? fm.removeItem(at: current)
            try? fm.moveItem(at: backup, to: current)
            cleanupStaging()
            reset()
            post(.failed("重启应用失败，已恢复原版本"))
        }
    }

    // MARK: - 辅助

    private func sha256Hex(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupStaging() {
        lock.lock()
        let dir = stagingDir
        lock.unlock()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func reset() {
        lock.lock()
        task = nil
        stagingDir = nil
        expectedSHA256 = nil
        expectedVersion = nil
        lock.unlock()
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func fail(_ message: String) -> Failure { Failure(message: message) }

    private func post(_ event: Event) {
        DispatchQueue.main.async { [onEvent] in onEvent?(event) }
    }
}
