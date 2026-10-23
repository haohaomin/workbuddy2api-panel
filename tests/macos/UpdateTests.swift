import Foundation
import CryptoKit
import Darwin

@main
struct UpdateTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        checks += 1
        if try !condition() { throw UpdateFailure("FAIL: " + label) }
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw UpdateFailure("FAIL: expected rejection: " + label)
    }
    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let version = "2026.10.20.1700"
        let name = "wb2api-panel-\(version)-darwin-\(UpdatePolicy.architecture)-update.zip"
        let url = "https://github.com/\(UpdatePolicy.repository)/releases/download/v\(version)/\(name)"
        let digest = "sha256:" + SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let asset = ReleaseAsset(name: name, browser_download_url: url, digest: digest, size: archive.count, state: "uploaded")
        let release = ReleaseInfo(tag_name: "v" + version, draft: false, prerelease: false, assets: [asset])
        try expect(AppVersion("2026.10.1.001")! > AppVersion("2026.9.30.2359")!, "numeric date comparison")
        try expect(AppVersion("2026.10.20.711")! < AppVersion("2026.10.20.1041")!, "numeric time comparison")
        try expect(AppVersion("1.2.3") == nil && AppVersion("2026.13.20.711") == nil, "reject non-timestamp versions")
        try expect(try UpdatePolicy.select(release, current: version) == nil, "same version")
        try expect(try UpdatePolicy.select(release, current: "2026.10.21.100") == nil, "no downgrade")
        try expect(try UpdatePolicy.select(release, current: "dev")?.version == version, "dev may opt into release")
        try rejects("prerelease") { _ = try UpdatePolicy.select(ReleaseInfo(tag_name: "v"+version, draft: false, prerelease: true, assets: [asset]), current: "dev") }
        try rejects("missing compatible asset") { _ = try UpdatePolicy.select(ReleaseInfo(tag_name: "v"+version, draft: false, prerelease: false, assets: []), current: "dev") }
        let wrongURL = ReleaseAsset(name: name, browser_download_url: url.replacingOccurrences(of: UpdatePolicy.repository, with: "attacker/repo"), digest: digest, size: archive.count, state: "uploaded")
        try rejects("other repository") { _ = try UpdatePolicy.select(ReleaseInfo(tag_name: "v"+version, draft: false, prerelease: false, assets: [wrongURL]), current: "dev") }
        let noDigest = ReleaseAsset(name: name, browser_download_url: url, digest: nil, size: archive.count, state: "uploaded")
        try rejects("missing digest") { _ = try UpdatePolicy.select(ReleaseInfo(tag_name: "v"+version, draft: false, prerelease: false, assets: [noDigest]), current: "dev") }
        try UpdatePolicy.verifyArchive(archive, asset: asset)
        checks += 1
        var damaged = archive
        damaged[0] ^= 1
        try rejects("tampered download") { try UpdatePolicy.verifyArchive(damaged, asset: asset) }
        for name in ["traversal", "symlink", "duplicate", "absolute", "foreign", "local-header"] {
            let bad = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent(name + ".zip"))
            try rejects(name) { try UpdatePolicy.validateZIP(bad) }
        }
        try UpdatePolicy.validateBundle(fixture, version: version)
        checks += 1
        try rejects("bundle version mismatch") { try UpdatePolicy.validateBundle(fixture, version: "2026.10.20.1701") }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("wb2api-updater-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let extracted = root.appendingPathComponent("extracted")
        try UpdatePolicy.run("/usr/bin/ditto", ["-x", "-k", CommandLine.arguments[2], extracted.path])
        try UpdatePolicy.validateBundle(extracted.appendingPathComponent("WorkBuddy2API.app"), version: version)
        checks += 1
        func plan(_ name: String) throws -> InstallPlan {
            let parent = root.appendingPathComponent(name)
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let target = parent.appendingPathComponent("WorkBuddy2API.app")
            try fm.copyItem(at: fixture, to: target)
            // Mark the old bundle so rollback and backup assertions distinguish it.
            try Data("old application".utf8).write(to: target.appendingPathComponent("old-marker"))
            let workspace = parent.appendingPathComponent(".WorkBuddy2API-update-" + UUID().uuidString)
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: fixture, to: workspace.appendingPathComponent("WorkBuddy2API.app"))
            return InstallPlan(target: target.path, workspace: workspace.path, version: version,
                               oldPID: getpid(), restartService: false, token: UUID().uuidString)
        }
        let lockPlan = try plan("locking")
        let lock = try UpdateInstaller.installationLock(for: lockPlan.app)
        try rejects("concurrent installer") { _ = try UpdateInstaller.installationLock(for: lockPlan.app) }
        flock(lock, LOCK_UN); close(lock)
        let nextLock = try UpdateInstaller.installationLock(for: lockPlan.app)
        close(nextLock)
        checks += 1
        let swapPlan = try plan("atomic-swap")
        try UpdateInstaller.swap(swapPlan.app, swapPlan.staged)
        try expect(fm.fileExists(atPath: swapPlan.app.path) &&
                   fm.fileExists(atPath: swapPlan.staged.appendingPathComponent("old-marker").path), "atomic swap keeps both apps")
        try UpdateInstaller.swap(swapPlan.app, swapPlan.staged)
        try expect(fm.fileExists(atPath: swapPlan.app.appendingPathComponent("old-marker").path), "atomic restoration")
        let archiveFailure = try plan("rollback-archive-failure")
        try Data("obstruct optional archive".utf8).write(to: archiveFailure.directory.appendingPathComponent("failed"))
        var archiveRestored = false
        try rejects("rollback archive blocked") {
            try UpdateInstaller.replace(archiveFailure, verifyLaunch: { throw UpdateFailure("Simulated startup failure") }, restoreLaunch: { archiveRestored = true })
        }
        try expect(archiveRestored && fm.fileExists(atPath: archiveFailure.app.appendingPathComponent("old-marker").path),
                   "optional diagnostics cannot prevent rollback")
        let success = try plan("success")
        try UpdateInstaller.replace(success, verifyLaunch: {}, restoreLaunch: { throw UpdateFailure("Unexpected rollback") })
        try expect(fm.fileExists(atPath: success.backup.appendingPathComponent("old-marker").path), "backup retained")
        try expect(!fm.fileExists(atPath: success.app.appendingPathComponent("old-marker").path), "new bundle installed")
        let failure = try plan("rollback")
        var relaunched = false
        try rejects("startup failure") {
            try UpdateInstaller.replace(failure, verifyLaunch: { throw UpdateFailure("Simulated new process failure") }, restoreLaunch: { relaunched = true })
        }
        try expect(relaunched && fm.fileExists(atPath: failure.app.appendingPathComponent("old-marker").path), "old app restored and relaunched")
        let invalid = try plan("invalid")
        try Data("bad".utf8).write(to: invalid.staged.appendingPathComponent("Contents/Resources/wb2api"))
        try rejects("corrupt staged executable") { try UpdateInstaller.replace(invalid, verifyLaunch: {}, restoreLaunch: {}) }
        try expect(fm.fileExists(atPath: invalid.app.appendingPathComponent("old-marker").path), "invalid package leaves original untouched")
        // Cleanup must never remove active/incomplete installs or follow links.
        try JSONEncoder().encode(success).write(to: success.file)
        try expect(try UpdateInstaller.clearBackups(for: success.app) == 0,
                   "unfinished update backup retained")
        try Data("completed".utf8).write(to: success.directory.appendingPathComponent("result.txt"))
        let cleanupLock = try UpdateInstaller.installationLock(for: success.app)
        try rejects("cleanup while installer holds lock") { _ = try UpdateInstaller.clearBackups(for: success.app) }
        flock(cleanupLock, LOCK_UN); close(cleanupLock)
        try expect(fm.fileExists(atPath: success.backup.path), "locked backup untouched")
        let foreignPlan = InstallPlan(target: success.app.deletingLastPathComponent().appendingPathComponent("Other/WorkBuddy2API.app").path,
                                      workspace: success.workspace, version: success.version,
                                      oldPID: success.oldPID, restartService: false, token: success.token)
        try JSONEncoder().encode(foreignPlan).write(to: success.file)
        try expect(try UpdateInstaller.clearBackups(for: success.app) == 0, "foreign installation ignored")
        try JSONEncoder().encode(success).write(to: success.file)
        let savedBackup = success.directory.appendingPathComponent("saved-backup")
        try fm.moveItem(at: success.backup.deletingLastPathComponent(), to: savedBackup)
        try fm.createSymbolicLink(at: success.backup.deletingLastPathComponent(), withDestinationURL: savedBackup)
        try expect(try UpdateInstaller.clearBackups(for: success.app) == 0, "symlink backup parent ignored")
        try expect(fm.fileExists(atPath: savedBackup.appendingPathComponent("WorkBuddy2API.app").path), "symlink destination retained")
        try fm.removeItem(at: success.backup.deletingLastPathComponent())
        try fm.moveItem(at: savedBackup, to: success.backup.deletingLastPathComponent())
        let userData = success.app.deletingLastPathComponent().appendingPathComponent("config.json")
        try Data("user data sentinel".utf8).write(to: userData)
        try expect(try UpdateInstaller.clearBackups(for: success.app) == 1, "completed backup removed")
        try expect(!fm.fileExists(atPath: success.backup.path) && fm.fileExists(atPath: success.app.path), "current app preserved")
        try expect(fm.fileExists(atPath: success.file.path), "supervisor plan retained")
        try expect(try String(contentsOf: userData, encoding: .utf8) == "user data sentinel", "user data unchanged")
        try expect(try UpdateInstaller.clearBackups(for: success.app) == 0, "repeat cleanup is harmless")
        print("PASS: \(checks) updater policy, archive integrity, installation, rollback and cleanup checks")
    }
}
