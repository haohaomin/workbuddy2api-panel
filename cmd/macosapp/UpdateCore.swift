import Foundation
import CryptoKit

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// A cancellation ticket shared with background verification. A cancelled
// network callback must never hand off a prepared application for installation.
final class UpdateOperation {
    private let lock = NSLock()
    private var cancelled = false
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func check() throws {
        if !isActive { throw URLError(.cancelled) }
    }
}

struct AppVersion: Comparable, Equatable {
    let components: [Int]
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), let time = Int(parts[3]),
              (2020...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(time / 100), (0...59).contains(time % 100) else { return nil }
        components = [year, month, day, time]
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct ReleaseAsset: Decodable, Equatable {
    let name: String
    let browser_download_url: String
    let digest: String?
    let size: Int
    let state: String
}
struct ReleaseInfo: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]
}
struct UpdateManifest: Decodable {
    let schema: Int
    let release: ReleaseInfo
}
struct AvailableUpdate: Equatable {
    let version: String
    let asset: ReleaseAsset
}

enum UpdatePolicy {
    static let repository = "haohaomin/workbuddy2api-panel"
    static let manifestURL = URL(string: "https://github.com/\(repository)/releases/latest/download/macos-update.json")!
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let bundleID = "com.workbuddy2api.panel"
    static let maxArchiveSize = 100 * 1024 * 1024
    #if arch(arm64)
    static let architecture = "arm64"
    static let cpu: UInt32 = 0x0100000c
    #else
    static let architecture = "amd64"
    static let cpu: UInt32 = 0x01000007
    #endif

    static func select(_ release: ReleaseInfo, current: String) throws -> AvailableUpdate? {
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"),
              let remote = AppVersion(release.tag_name) else { throw UpdateFailure("发布版本格式不受支持。") }
        if let local = AppVersion(current), remote <= local { return nil }
        let version = String(release.tag_name.dropFirst())
        let name = "wb2api-panel-\(version)-darwin-\(architecture)-update.zip"
        let matches = release.assets.filter { $0.name == name }
        guard matches.count == 1 else { throw UpdateFailure("最新发布尚未提供兼容的一键更新包，请稍后检查。") }
        let asset = matches[0]
        let expectedURL = "https://github.com/\(repository)/releases/download/\(release.tag_name)/\(name)"
        guard asset.browser_download_url == expectedURL, asset.state == "uploaded",
              asset.size > 0, asset.size <= maxArchiveSize,
              let digest = asset.digest, digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw UpdateFailure("更新包来源、大小或校验摘要不符合要求。")
        }
        return AvailableUpdate(version: version, asset: asset)
    }

    static func verifyArchive(_ data: Data, asset: ReleaseAsset) throws {
        guard data.count == asset.size, data.count <= maxArchiveSize else { throw UpdateFailure("更新包大小校验失败。") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard asset.digest == "sha256:" + hash else { throw UpdateFailure("更新包 SHA-256 校验失败，已取消安装。") }
        try validateZIP(data)
    }

    // Only a small, ordinary ZIP containing this .app is accepted. Validate before
    // extraction: no traversal, symlinks, encrypted entries, ZIP64 or zip bombs.
    static func validateZIP(_ data: Data) throws {
        func u16(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard data.count >= 22 else { throw UpdateFailure("更新压缩包无效。") }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == data.count { end = i; break }
        }
        guard let end = end, u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == u16(end + 10), (1...10000).contains(u16(end + 10)) else {
            throw UpdateFailure("更新压缩包目录无效。")
        }
        var offset = u32(end + 16)
        guard offset >= 0, offset + u32(end + 12) == end else { throw UpdateFailure("更新压缩包边界无效。") }
        var total = 0
        var paths = Set<String>()
        for _ in 0..<u16(end + 10) {
            guard offset + 46 <= end, u32(offset) == 0x02014b50 else { throw UpdateFailure("更新压缩包目录损坏。") }
            let length = u16(offset + 28)
            let next = offset + 46 + length + u16(offset + 30) + u16(offset + 32)
            guard next <= end,
                  let name = String(data: data[(offset + 46)..<(offset + 46 + length)], encoding: .utf8),
                  name.hasPrefix("WorkBuddy2API.app/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."),
                  !name.contains("//"), paths.insert(name.lowercased()).inserted,
                  u16(offset + 8) & 1 == 0, [0, 8].contains(u16(offset + 10)),
                  [0, 0x8000, 0x4000].contains((u32(offset + 38) >> 16) & 0xf000) else {
                throw UpdateFailure("更新压缩包包含不允许的路径或文件类型。")
            }
            let local = u32(offset + 42)
            guard local + 30 <= offset, u32(local) == 0x04034b50,
                  u16(local + 26) == length,
                  local + 30 + length + u16(local + 28) + u32(offset + 20) <= offset,
                  data[(local + 30)..<(local + 30 + length)] == data[(offset + 46)..<(offset + 46 + length)] else {
                throw UpdateFailure("更新压缩包文件头不一致。")
            }
            total += u32(offset + 24)
            guard total <= 500 * 1024 * 1024 else { throw UpdateFailure("解压后的更新包过大。") }
            offset = next
        }
        guard offset == end else { throw UpdateFailure("更新压缩包目录不完整。") }
    }

    static func run(_ executable: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateFailure("校验或解压失败：\(URL(fileURLWithPath: executable).lastPathComponent)。") }
    }

    static func validateBundle(_ app: URL, version: String) throws {
        let fm = FileManager.default
        guard app.lastPathComponent == "WorkBuddy2API.app",
              let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleID,
              plist["CFBundleExecutable"] as? String == "WorkBuddy2API",
              plist["CFBundleShortVersionString"] as? String == version,
              plist["WBUpdaterProtocol"] as? Int == 1 else { throw UpdateFailure("应用标识、版本或更新协议校验失败。") }
        guard let entries = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateFailure("无法读取更新应用。")
        }
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw UpdateFailure("更新应用不能包含符号链接。")
            }
        }
        for path in ["Contents/MacOS/WorkBuddy2API", "Contents/Resources/wb2api"] {
            let file = app.appendingPathComponent(path)
            guard fm.isExecutableFile(atPath: file.path) else { throw UpdateFailure("更新包缺少可执行文件。") }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 8) ?? Data()
            guard header.count == 8, Array(header.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else {
                throw UpdateFailure("更新包不是有效的 macOS 应用。")
            }
            let type = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
            guard type == cpu else { throw UpdateFailure("更新包芯片架构不匹配。") }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
}
