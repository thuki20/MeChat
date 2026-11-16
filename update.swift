import AppKit
import Foundation
import CryptoKit

// ============================================================
//  MeChat 应用内更新（OTA）
//  契约与 IslandHop 一致：门户 /home/updates/mchat/manifest.json
//  字段 version / notes / url / sha256 / size；多源兜底 + sha256 强校验。
// ============================================================

private let UPDATE_FEEDS = [
    "https://203.195.201.85/home/updates/mchat/manifest.json",
    "https://ncsai.top/home/updates/mchat/manifest.json",
    "http://203.195.201.85/.well-known/acme-challenge/mchat/manifest.json",
]

private let UPDATE_CACHE = expand("~/Library/Caches/local.tsuki.mechat/update")

struct UpdateInfo {
    let version: String
    let notes: String
    let url: String
    let sha256: String
    let size: Int64
}

enum UpdateCheckResult {
    case available(UpdateInfo)   // 有更新
    case upToDate                // 已是最新
    case failed(String)          // 检查失败（含原因）
}

// 纯函数：数字版本比较，逐段比大小，禁止降级。供单测与逻辑共用。
func compareVersions(_ a: String, _ b: String) -> Int {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".").map { Int($0) ?? 0 }
    }
    let pa = parts(a), pb = parts(b)
    let n = max(pa.count, pb.count)
    for i in 0..<n {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x > y { return 1 }
        if x < y { return -1 }
    }
    return 0
}

// 纯函数：解析 manifest。version 不比本地新返回 upToDate；url/sha256/size 齐全才允许安装。
func parseUpdateManifest(_ data: Data, currentVersion: String) -> UpdateCheckResult {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ver = obj["version"] as? String, !ver.isEmpty,
          let url = obj["url"] as? String, url.hasPrefix("http"),
          let sha = obj["sha256"] as? String, sha.count == 64,
          let size = (obj["size"] as? NSNumber)?.int64Value, size > 0
    else {
        return .failed("更新清单格式异常")
    }
    if compareVersions(ver, currentVersion) <= 0 { return .upToDate }
    let notes = obj["notes"] as? String ?? ""
    return .available(UpdateInfo(version: ver, notes: notes, url: url,
                                 sha256: sha.lowercased(), size: size))
}

final class AppUpdater {
    static let shared = AppUpdater()
    private let session = URLSession(configuration: .ephemeral)
    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // 多源顺序尝试：IP HTTPS → 域名 HTTPS → IP HTTP(ACME 兜底)，任一成功即返回。
    func check() -> UpdateCheckResult {
        var lastError = "无法连接更新服务器"
        for feed in UPDATE_FEEDS {
            guard let url = URL(string: feed) else { continue }
            let sem = DispatchSemaphore(value: 0)
            var got: Data?
            var err: Error?
            let task = session.dataTask(with: url) { data, resp, error in
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    err = NSError(domain: "update", code: http.statusCode, userInfo: nil)
                } else {
                    got = data; err = error
                }
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 8) == .timedOut {
                task.cancel(); lastError = "连接更新服务器超时"; continue
            }
            if let error = err { lastError = "\(feed)：\(error.localizedDescription)"; continue }
            guard let data = got else { lastError = "更新服务器无响应"; continue }
            let result = parseUpdateManifest(data, currentVersion: currentVersion)
            switch result {
            case .upToDate: return result
            case .available: return result
            case .failed(let msg): lastError = "\(feed)：\(msg)"
            }
        }
        return .failed(lastError)
    }

    // 下载 + sha256/size 校验 + 解压 + 写自替换脚本。
    // 成功返回 work 目录，调用方随后 NSApp.terminate 让脚本接管换包重启。
    func downloadAndPrepare(_ info: UpdateInfo, progress: @escaping (Double) -> Void) throws -> String {
        try? FileManager.default.removeItem(atPath: UPDATE_CACHE)
        try FileManager.default.createDirectory(atPath: UPDATE_CACHE, withIntermediateDirectories: true)
        let zipPath = UPDATE_CACHE + "/update.zip"
        guard let url = URL(string: info.url) else { throw UpdateError("更新地址无效") }

        // 用 DownloadDelegate 拿进度；同步等待完成
        let dl = UpdateDownloader(progress: progress)
        let data = try dl.fetch(url: url)
        guard Int64(data.count) == info.size else {
            throw UpdateError("更新包大小不符（\(data.count) / \(info.size)）")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256 else {
            throw UpdateError("更新包校验失败（sha256 不匹配，已丢弃）")
        }
        try data.write(to: URL(fileURLWithPath: zipPath), options: .atomic)

        let newDir = UPDATE_CACHE + "/new"
        try FileManager.default.createDirectory(atPath: newDir, withIntermediateDirectories: true)
        let (_, code) = shell(["/usr/bin/ditto", "-x", "-k", zipPath, newDir])
        guard code == 0 else { throw UpdateError("更新包解压失败") }
        guard FileManager.default.fileExists(atPath: newDir + "/MeChat.app") else {
            throw UpdateError("更新包内缺少 MeChat.app")
        }

        try writeApplyScript(version: info.version)
        return UPDATE_CACHE
    }

    // 覆盖脚本：先写 ready 放行主程序退出，等父进程结束再换包并重启。
    // 失败自动回滚到 .old，错误信息落 error.txt。
    private func writeApplyScript(version: String) throws {
        let target = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        # MeChat macOS 覆盖更新 → \(version)
        TARGET="\(target)"
        WORK="\(UPDATE_CACHE)"
        BACKUP="$TARGET.old"
        if [ ! -w "$(dirname "$TARGET")" ]; then echo "安装目录不可写，请手动替换" > "$WORK/error.txt"; echo fail > "$WORK/ready"; exit 1; fi
        echo ok > "$WORK/ready"
        for i in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        sleep 0.5
        rm -rf "$BACKUP"
        if ! mv "$TARGET" "$BACKUP"; then echo "无法移走当前版本" > "$WORK/error.txt"; exit 1; fi
        if ! mv "$WORK/new/MeChat.app" "$TARGET"; then mv "$BACKUP" "$TARGET"; echo "无法放入新版本，已还原" > "$WORK/error.txt"; exit 1; fi
        open "$TARGET"
        rm -rf "$BACKUP"
        """
        try script.write(toFile: UPDATE_CACHE + "/apply.sh", atomically: true, encoding: .utf8)
        _ = shell(["/bin/chmod", "+x", UPDATE_CACHE + "/apply.sh"])
    }

    // 启动覆盖脚本，并等它预检完成（写 ready）。ok 表示可以继续退出主程序。
    func launchInstaller() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [UPDATE_CACHE + "/apply.sh"]
        try p.run()

        let ready = UPDATE_CACHE + "/ready"
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: ready, encoding: .utf8) {
                let status = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if status == "ok" { return }
                if status == "fail" {
                    let msg = (try? String(contentsOfFile: UPDATE_CACHE + "/error.txt", encoding: .utf8)) ?? "安装准备失败"
                    throw UpdateError(msg)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw UpdateError("无法启动更新程序，请手动下载安装")
    }
}

struct UpdateError: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

// URLSession 下载器：用 delegate 回调进度，同步等待结果。
private final class UpdateDownloader: NSObject, URLSessionDataDelegate {
    private let progress: (Double) -> Void
    private var buffer = Data()
    private var expected: Int64 = 0
    private var sem = DispatchSemaphore(value: 0)
    private var result: Data?
    private var error: Error?

    init(progress: @escaping (Double) -> Void) {
        self.progress = progress
        super.init()
    }

    func fetch(url: URL) throws -> Data {
        // 延迟创建：delegate 需要 self，必须等 super.init 完成后再构造
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: url)
        task.resume()
        if sem.wait(timeout: .now() + 180) == .timedOut {
            task.cancel()
            throw UpdateError("下载超时")
        }
        if let error = error { throw error }
        guard let result = result else { throw UpdateError("下载失败") }
        return result
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expected = response.expectedContentLength
        buffer.removeAll()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if expected > 0 {
            progress(Double(buffer.count) / Double(expected))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { self.error = error } else { result = buffer }
        sem.signal()
    }
}
