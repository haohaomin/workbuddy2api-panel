import Foundation
import Darwin

struct InstallPlan: Codable {
    let target: String
    let workspace: String
    let version: String
    let oldPID: Int32
    let restartService: Bool
    let token: String
    var directory: URL { URL(fileURLWithPath: workspace, isDirectory: true) }
    var app: URL { URL(fileURLWithPath: target, isDirectory: true) }
    var staged: URL { directory.appendingPathComponent("WorkBuddy2API.app") }
    var backup: URL { directory.appendingPathComponent("backup/WorkBuddy2API.app") }
    var receipt: URL { directory.appendingPathComponent("ready.json") }
    var launcherReceipt: URL { directory.appendingPathComponent("launcher-ready.json") }
    var file: URL { directory.appendingPathComponent("plan.json") }

    func validate() throws {
        let fm = FileManager.default
        guard app.path == target, app.lastPathComponent == "WorkBuddy2API.app",
              !target.split(separator: "/").contains(".."),
              try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw UpdateFailure("应用安装路径必须是绝对路径，且不能经过符号链接。")
        }
        guard directory.path == workspace, !workspace.split(separator: "/").contains(".."),
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              directory.deletingLastPathComponent().resolvingSymlinksInPath().path == app.deletingLastPathComponent().resolvingSymlinksInPath().path,
              directory.lastPathComponent.hasPrefix(".WorkBuddy2API-update-") else {
            throw UpdateFailure("更新暂存目录必须与应用位于同一目录，且不能经过符号链接。")
        }
        guard AppVersion(version) != nil, UUID(uuidString: token) != nil, oldPID > 1 else {
            throw UpdateFailure("更新计划的版本或交接标识无效。")
        }
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            throw UpdateFailure("安装目录不可写，请将应用放在可写的“应用程序”目录。")
        }
    }
}

struct UpdateReceipt: Codable {
    let token: String
    let version: String
    let pid: Int32
    let serverPID: Int32?
}

// The helper is a copy of the currently trusted launcher, outside the bundle
// being replaced. It runs without AppKit and never writes the user's data tree.
enum UpdateInstaller {
    // Only remove backups belonging to successful updates of this installation.
    // Keep plans/receipts: a running update supervisor may still use them.
    static func clearBackups(for app: URL) throws -> Int {
        let fm = FileManager.default
        let app = app.standardizedFileURL
        guard app.lastPathComponent == "WorkBuddy2API.app",
              app.resolvingSymlinksInPath().path == app.path else {
            throw UpdateFailure("请从正常安装目录中的应用清理备份。")
        }
        let lock = try installationLock(for: app)
        defer { flock(lock, LOCK_UN); close(lock) }
        func isReal(_ url: URL, directory: Bool) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]),
                  values.isSymbolicLink != true else { return false }
            return directory ? values.isDirectory == true : values.isRegularFile == true
        }
        var removed = 0
        let parent = app.deletingLastPathComponent()
        for name in try fm.contentsOfDirectory(atPath: parent.path) {
            let directory = parent.appendingPathComponent(name, isDirectory: true)
            guard directory.lastPathComponent.hasPrefix(".WorkBuddy2API-update-"),
                  isReal(directory, directory: true),
                  isReal(directory.appendingPathComponent("plan.json"), directory: false),
                  isReal(directory.appendingPathComponent("result.txt"), directory: false),
                  let plan = try? load(directory.appendingPathComponent("plan.json").path),
                  plan.app.path == app.path,
                  isReal(plan.backup.deletingLastPathComponent(), directory: true),
                  isReal(plan.backup, directory: true) else { continue }
            do {
                try fm.removeItem(at: plan.backup)
                removed += 1
            } catch {
                throw UpdateFailure("已清除 \(removed) 份备份，其余清理失败：\(error.localizedDescription)")
            }
        }
        return removed
    }

    // Foundation launches each Process in its own process group on macOS.
    // Before exec, put the update's server back in the launcher's group so the
    // helper can clean up both even if the launcher crashes before its receipt.
    static func runUpdateServer(_ arguments: [String]) -> Never {
        let parent = getppid()
        guard !arguments.isEmpty, parent > 1, getpgid(parent) == parent,
              setpgid(0, parent) == 0 else {
            fputs("Cannot join the update launcher's process group.\n", stderr)
            exit(2)
        }
        let strings = arguments.map { strdup($0) }
        var argv = strings + [nil]
        argv.withUnsafeMutableBufferPointer { buffer in
            _ = execv(arguments[0], buffer.baseAddress!)
        }
        fputs("Cannot execute the update's server.\n", stderr)
        exit(2)
    }

    static func load(_ path: String) throws -> InstallPlan {
        let plan = try JSONDecoder().decode(InstallPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard plan.file.path == path else { throw UpdateFailure("更新计划路径无效。") }
        try plan.validate()
        return plan
    }

    static func launch(_ plan: InstallPlan, receipt: Bool, supervised: Bool = false) throws -> Process {
        let p = Process()
        p.executableURL = plan.app.appendingPathComponent("Contents/MacOS/WorkBuddy2API")
        var args: [String] = plan.restartService ? [] : ["--no-start"]
        if receipt { args += ["--update-session", plan.file.path] }
        else { args += ["--update-rollback", plan.file.path] }
        if supervised { args.append("--update-child") }
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        // Do not keep a pipe into the exiting parent open.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    // The new bundle supplies this supervisor even when the installer helper
    // was copied from a pre-fix application. It stays alive until the GUI and
    // its server are cleaned up, so even an old helper cannot roll back early.
    // Keep the old trusted helper responsible for validation and file replacement.
    static func supervise(_ path: String) -> Int32 {
        let operation = UpdateOperation()
        var sources: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { operation.cancel() }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        do {
            let plan = try load(path)
            let child = try launch(plan, receipt: true, supervised: true)
            // Legacy helpers escalate after 7 seconds. Finish within that
            // window. If the GUI has already crashed, kill its backend without
            // a grace period so a legacy helper's 2-second stability check
            // cannot accept a live orphan while this supervisor cleans up.
            defer { stop(child, grace: child.isRunning ? 2 : 0, killedWait: 2) }
            var forwarded = false
            while child.isRunning && operation.isActive {
                if !forwarded, let data = try? Data(contentsOf: plan.launcherReceipt),
                   let receipt = try? JSONDecoder().decode(UpdateReceipt.self, from: data),
                   receipt.token == plan.token, receipt.version == plan.version,
                   receipt.pid == child.processIdentifier {
                    let confirmed = UpdateReceipt(token: plan.token, version: plan.version,
                                                  pid: getpid(), serverPID: receipt.serverPID)
                    try JSONEncoder().encode(confirmed).write(to: plan.receipt, options: .atomic)
                    forwarded = true
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return child.isRunning ? 1 : child.terminationStatus
        } catch {
            fputs("更新启动监督失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func writeReceipt(_ plan: InstallPlan, serverPID: Int32?) throws {
        let receipt = UpdateReceipt(token: plan.token, version: plan.version, pid: getpid(), serverPID: serverPID)
        let destination = CommandLine.arguments.contains("--update-child") ? plan.launcherReceipt : plan.receipt
        try JSONEncoder().encode(receipt).write(to: destination, options: .atomic)
    }

    static func stop(_ child: Process, grace: TimeInterval = 7, killedWait: TimeInterval = 3) {
        // The group remains addressable after its launcher has exited. Never
        // use the helper's group or enumerate unrelated processes by name/port.
        let group = child.processIdentifier
        guard group > 1, group != getpgrp() else { return }
        kill(-group, SIGTERM)
        if child.isRunning { child.terminate() }
        let limit = Date().addingTimeInterval(grace)
        while (child.isRunning || kill(-group, 0) == 0) && Date() < limit {
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Include a server that ignored SIGTERM or outlived a crashed launcher.
        kill(-group, SIGKILL)
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        // Give orphaned descendants time to exit and release their sockets
        // before the restored application attempts to bind the same port.
        let killedDeadline = Date().addingTimeInterval(killedWait)
        while kill(-group, 0) == 0 && Date() < killedDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // The lock file stays in place; unlinking a live flock file would allow a
    // second helper to lock a different inode and install concurrently.
    static func installationLock(for app: URL) throws -> Int32 {
        let path = app.deletingLastPathComponent().appendingPathComponent(".WorkBuddy2API-update.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UpdateFailure("无法创建更新锁，请检查安装目录权限。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw UpdateFailure("另一个更新正在安装，请等待完成后重试。")
        }
        return fd
    }

    static func swap(_ first: URL, _ second: URL) throws {
        // macOS RENAME_SWAP exchanges both directories in one filesystem
        // operation. The application's installed path never disappears.
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure("无法原子替换应用（\(String(cString: strerror(errno)))），原应用保持原位。")
        }
    }

    // Factored for integration tests that supply a fake relaunch/handshake.
    static func replace(_ plan: InstallPlan, verifyLaunch: () throws -> Void,
                        restoreLaunch: () throws -> Void) throws {
        let fm = FileManager.default
        try plan.validate()
        try UpdatePolicy.validateBundle(plan.staged, version: plan.version)
        guard !fm.fileExists(atPath: plan.backup.path) else { throw UpdateFailure("备份已存在，拒绝覆盖。") }
        try fm.createDirectory(at: plan.backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try swap(plan.app, plan.staged)
        var oldApp = plan.staged
        do {
            try fm.moveItem(at: plan.staged, to: plan.backup)
            oldApp = plan.backup
            try verifyLaunch()
        } catch {
            let originalError = error
            // Restore the installed path first; archiving the rejected build is
            // best effort and must never prevent the old app from returning.
            try swap(plan.app, oldApp)
            let failed = plan.directory.appendingPathComponent("failed/WorkBuddy2API.app")
            try? fm.createDirectory(at: failed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldApp, to: failed)
            try restoreLaunch()
            throw UpdateFailure("新版未能启动，已恢复旧应用。\(originalError.localizedDescription)")
        }
    }

    static func apply(_ path: String) -> Int32 {
        var recoverOriginal: (() -> Void)?
        do {
            let plan = try load(path)
            let originalVersion = NSDictionary(contentsOf: plan.app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            let lock = try installationLock(for: plan.app)
            defer { flock(lock, LOCK_UN); close(lock) }
            try UpdatePolicy.validateBundle(plan.staged, version: plan.version)
            try Data(plan.token.utf8).write(to: plan.directory.appendingPathComponent("helper-ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(30)
            while kill(plan.oldPID, 0) == 0 || errno == EPERM {
                guard Date() < deadline else { throw UpdateFailure("旧应用未退出，已取消替换。") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            // If revalidation or the filesystem operation fails after the old
            // process has exited, bring back the unchanged original application.
            recoverOriginal = {
                let installedVersion = NSDictionary(contentsOf: plan.app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
                guard let originalVersion = originalVersion, installedVersion == originalVersion else { return }
                try? Data("安装未完成，已重新打开原应用。".utf8)
                    .write(to: plan.directory.appendingPathComponent("rollback.txt"), options: .atomic)
                _ = try? launch(plan, receipt: false)
            }
            try replace(plan, verifyLaunch: {
                let child = try launch(plan, receipt: true)
                let limit = Date().addingTimeInterval(45)
                while child.isRunning && Date() < limit {
                    if let data = try? Data(contentsOf: plan.receipt),
                       let receipt = try? JSONDecoder().decode(UpdateReceipt.self, from: data),
                       receipt.token == plan.token, receipt.version == plan.version, receipt.pid == child.processIdentifier {
                        // A short stability window catches an immediate post-start crash.
                        Thread.sleep(forTimeInterval: 2)
                        let serverAlive = receipt.serverPID.map { $0 > 1 && kill($0, 0) == 0 } ?? false
                        if child.isRunning && (!plan.restartService || serverAlive) { return }
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                stop(child)
                throw UpdateFailure("未收到新版就绪确认。")
            }, restoreLaunch: {
                // Put the explanation beside the installed app, not in the data directory.
                try Data("新版启动失败，已自动恢复旧版。可查看更新日志。".utf8)
                    .write(to: plan.directory.appendingPathComponent("rollback.txt"), options: .atomic)
                _ = try launch(plan, receipt: false)
                recoverOriginal = nil
            })
            recoverOriginal = nil
            try Data("更新至 v\(plan.version) 成功；旧版备份：\(plan.backup.path)".utf8)
                .write(to: plan.directory.appendingPathComponent("result.txt"), options: .atomic)
            return 0
        } catch {
            recoverOriginal?()
            fputs("更新失败：\(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
