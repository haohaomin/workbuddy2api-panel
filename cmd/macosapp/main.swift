import AppKit
import Foundation
import Darwin

// The launcher owns only the server it starts. All UI and lifecycle transitions
// run on the main queue; readiness requests never block the window.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    enum State { case stopped, checking, starting, running, stopping, failed, external }
    private var state: State = .stopped
    private var process: Process?
    private var logFile: FileHandle?
    private var timer: Timer?
    private var request: URLSessionDataTask?
    private var generation = 0
    private var startedAt = Date()
    private var quitting = false
    private var stopError: String?
    private let updater = UpdateController()
    private var installPreparing = false
    private var installCommitted = false
    private var updateReceiptWritten = false
    private var updateResultTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WorkBuddy2API", isDirectory: true)
    private var panelURL = URL(string: "http://127.0.0.1:7863/panel/")!
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 1
        return URLSession(configuration: config)
    }()
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "未启动")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var panelButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        // SIGTERM from Activity Monitor also follows the normal shutdown path.
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            // terminateLater runs a nested AppKit loop. Enter it from the run
            // loop, not a dispatch callback that would block the main queue.
            source.setEventHandler {
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
        updater.onInstall = { [weak self] directory, update in self?.beginInstall(directory, update) }
        if CommandLine.arguments.contains("--no-start") {
            acknowledgeUpdate()
        } else { startService() }
        updater.startChecking()
        if CommandLine.arguments.contains("--update-rollback") { updater.showRollback() }
    }

    func applicationDidBecomeActive(_ notification: Notification) { updater.focused() }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }

    private func buildWindow() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let menuItem = NSMenuItem()
        menuItem.submenu = appMenu
        menu.addItem(menuItem)
        appMenu.addItem(withTitle: "退出 WorkBuddy2API", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WorkBuddy2API"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "WorkBuddy2API")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "本地服务控制台")
        subtitle.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 17, weight: .medium)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        address.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        address.isSelectable = true
        startButton = button("启动服务", #selector(startService))
        stopButton = button("停止服务", #selector(stopService))
        panelButton = button("打开面板", #selector(openPanel))
        let controls = NSStackView(views: [startButton, stopButton, panelButton])
        controls.spacing = 12
        let logButton = button("查看日志", #selector(openLog))
        let quitButton = button("退出应用", #selector(quitApp))
        let utilities = NSStackView(views: [logButton, quitButton])
        utilities.spacing = 12
        let footnote = NSTextField(labelWithString: "关闭此窗口或退出应用，会同时停止本应用启动的服务。")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        let separator = NSBox()
        separator.boxType = .separator
        let updateActions = NSStackView(views: [updater.button, updater.cancelButton, updater.releaseButton, updater.logButton])
        updateActions.spacing = 10
        let stack = NSStackView(views: [title, subtitle, status, detail, address, controls, utilities,
                                        separator, updater.text, updater.progress, updateActions, footnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(24, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updater.text.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updater.progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        render(.stopped, "点击启动服务，即可使用本地 API 与管理面板。")
    }

    private func render(_ next: State, _ message: String) {
        state = next
        let labels: [State: String] = [.stopped: "已停止", .checking: "正在检查…", .starting: "正在启动…",
                                     .running: "运行中", .stopping: "正在停止…", .failed: "服务异常", .external: "检测到其他服务"]
        status.stringValue = labels[next]!
        status.textColor = next == .running ? .systemGreen : (next == .failed ? .systemRed : .labelColor)
        detail.stringValue = message
        address.stringValue = panelURL.absoluteString
        startButton.isEnabled = !quitting && !installPreparing && [.stopped, .failed, .external].contains(next)
        stopButton.isEnabled = !quitting && !installPreparing && [.starting, .running].contains(next)
        panelButton.isEnabled = [.running, .external].contains(next)
    }

    private func configuredURL() throws -> URL {
        let config = root.appendingPathComponent("config.json")
        var listen = ":7863"
        if FileManager.default.fileExists(atPath: config.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            listen = object?["listen"] as? String ?? listen
        }
        if let override = ProcessInfo.processInfo.environment["WB2A_LISTEN"], !override.isEmpty { listen = override }
        // Match the server's bare-port, host:port, and [IPv6]:port forms.
        if !listen.contains(":") { listen = ":" + listen }
        var parts = URLComponents(string: "http://" + (listen.hasPrefix(":") ? "127.0.0.1" : "") + listen)
        if parts?.host == "0.0.0.0" { parts?.host = "127.0.0.1" }
        if parts?.host == "[::]" || parts?.host == "::" { parts?.host = "[::1]" }
        parts?.path = "/panel/"
        guard let url = parts?.url, let port = parts?.port, (1...65535).contains(port) else {
            throw NSError(domain: "WorkBuddy2API", code: 1, userInfo: [NSLocalizedDescriptionKey: "配置中的监听地址无效。"])
        }
        return url
    }

    private func probe(_ completion: @escaping (Bool) -> Void) {
        guard request == nil else { return }
        let currentGeneration = generation
        request = session.dataTask(with: panelURL) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration else { return }
                self.request = nil
                completion((response as? HTTPURLResponse)?.statusCode == 200)
            }
        }
        request?.resume()
    }

    private func cancelMonitoring() {
        generation += 1
        request?.cancel()
        request = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func startService() {
        guard process == nil, !quitting, [.stopped, .failed, .external].contains(state) else { return }
        cancelMonitoring()
        do { panelURL = try configuredURL() }
        catch { render(.failed, "无法读取配置：\(error.localizedDescription)"); return }
        render(.checking, "正在检查本地服务地址。")
        probe { [weak self] ready in
            guard let self = self, !self.quitting else { return }
            if ready {
                self.render(.external, "此地址已有服务。请先退出旧实例，再点击启动；本窗口不会停止其他进程。")
            } else {
                self.launchServer()
            }
        }
    }

    private func launchServer() {
        do {
            for name in ["auths", "data"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let logURL = root.appendingPathComponent("data/server.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            let log = try FileHandle(forWritingTo: logURL)
            logFile = log
            try log.seekToEnd()
            let child = Process()
            child.executableURL = Bundle.main.resourceURL!.appendingPathComponent("wb2api")
            child.arguments = ["-config", root.appendingPathComponent("config.json").path]
            child.currentDirectoryURL = root
            child.standardOutput = log
            child.standardError = log
            child.standardInput = FileHandle.nullDevice
            child.terminationHandler = { [weak self] task in
                RunLoop.main.perform(inModes: [.common]) { self?.serverExited(task) }
            }
            try child.run()
            process = child
            startedAt = Date()
            render(.starting, "服务启动后，可点击“打开面板”管理账号。")
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkHealth() }
            checkHealth()
        } catch {
            try? logFile?.close()
            logFile = nil
            render(.failed, "启动失败：\(error.localizedDescription)")
        }
    }

    private func checkHealth() {
        guard let child = process, child.isRunning, [.starting, .running].contains(state) else { return }
        probe { [weak self] ready in
            guard let self = self, self.process === child, [.starting, .running].contains(self.state) else { return }
            if ready {
                self.render(.running, "服务已就绪，可以打开面板或连接本地 API。")
                self.acknowledgeUpdate()
            } else if Date().timeIntervalSince(self.startedAt) > 30 && self.state == .starting {
                self.stopError = "服务未能在 30 秒内就绪，已停止。请查看日志后重试。"
                self.stopService()
            } else if self.state == .running {
                self.startedAt = Date()
                self.render(.starting, "暂时无法连接服务，正在重新检查。")
            }
        }
    }

    @objc private func stopService() {
        guard let child = process, state != .stopping else { return }
        cancelMonitoring()
        render(.stopping, "正在保存状态并停止服务…")
        if child.isRunning { child.terminate() }
        // A hung server must not leave an invisible process after the window exits.
        let deadline = Timer(timeInterval: 5, repeats: false) { [weak self, weak child] _ in
            guard let self = self, let child = child, self.process === child, child.isRunning else { return }
            kill(child.processIdentifier, SIGKILL)
        }
        RunLoop.main.add(deadline, forMode: .common)
    }

    private func serverExited(_ child: Process) {
        guard process === child else { return }
        let expected = state == .stopping
        cancelMonitoring()
        process = nil
        try? logFile?.close()
        logFile = nil
        if quitting { NSApp.reply(toApplicationShouldTerminate: true); return }
        if let error = stopError {
            stopError = nil
            render(.failed, error)
        } else if expected {
            render(.stopped, "服务已停止，点击“启动服务”可重新运行。")
        } else {
            render(.failed, "服务意外退出（状态码 \(child.terminationStatus)）。请查看日志后重试。")
        }
    }

    private func acknowledgeUpdate() {
        guard !updateReceiptWritten,
              let index = CommandLine.arguments.firstIndex(of: "--update-session"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        do {
            let plan = try UpdateInstaller.load(CommandLine.arguments[index + 1])
            guard plan.app.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                  plan.version == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                throw UpdateFailure("新版启动确认的路径或版本不匹配。")
            }
            let receipt = UpdateReceipt(token: plan.token, version: plan.version, pid: getpid(),
                                        serverPID: process?.processIdentifier)
            try JSONEncoder().encode(receipt).write(to: plan.receipt, options: .atomic)
            updateReceiptWritten = true
            let deadline = Date().addingTimeInterval(15)
            updateResultTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
                if FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("result.txt").path) {
                    self?.updater.showInstalled(plan.version)
                    timer.invalidate()
                } else if Date() > deadline { timer.invalidate() }
            }
        } catch { NSLog("Update readiness: %@", error.localizedDescription) }
    }

    private func beginInstall(_ directory: URL, _ update: AvailableUpdate) {
        guard !quitting else { return }
        installPreparing = true
        startButton.isEnabled = false
        stopButton.isEnabled = false
        let helper = Process()
        do {
            let plan = InstallPlan(target: Bundle.main.bundleURL.standardizedFileURL.path,
                workspace: directory.path, version: update.version, oldPID: getpid(),
                restartService: process != nil && state != .stopping, token: UUID().uuidString)
            try plan.validate()
            try JSONEncoder().encode(plan).write(to: plan.file, options: .atomic)
            let executable = directory.appendingPathComponent("update-helper")
            try FileManager.default.copyItem(at: Bundle.main.executableURL!, to: executable)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("data"),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = root.appendingPathComponent("data/updater.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            try log.seekToEnd()
            helper.executableURL = executable
            helper.arguments = ["--apply-update", plan.file.path]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = log
            helper.standardError = log
            try helper.run()
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(10)
                var ready = false
                while helper.isRunning && Date() < deadline {
                    if (try? String(contentsOf: directory.appendingPathComponent("helper-ready"), encoding: .utf8)) == plan.token {
                        ready = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                let confirmed = ready
                RunLoop.main.perform(inModes: [.common]) {
                    if confirmed {
                        self.installCommitted = true
                        NSApp.terminate(nil)
                    } else {
                        if helper.isRunning { helper.terminate() }
                        self.installPreparing = false
                        self.render(self.state, self.detail.stringValue)
                        self.updater.installationFailed(UpdateFailure("更新助手未能就绪，当前应用未替换。请查看 updater.log。"))
                    }
                }
            }
        } catch {
            if helper.isRunning { helper.terminate() }
            installPreparing = false
            render(state, detail.stringValue)
            updater.installationFailed(error)
        }
    }

    @objc private func openPanel() { NSWorkspace.shared.open(panelURL) }
    @objc private func openLog() {
        let log = root.appendingPathComponent("data/server.log")
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
        else {
            let alert = NSAlert()
            alert.messageText = "暂无日志"
            alert.informativeText = "服务启动后会在此处记录运行日志。"
            alert.beginSheetModal(for: window)
        }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if installPreparing && !installCommitted { return .terminateCancel }
        quitting = true
        updater.cancel()
        guard process != nil else { cancelMonitoring(); return .terminateNow }
        stopService()
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--apply-update") {
    guard CommandLine.arguments.indices.contains(index + 1) else { exit(2) }
    signal(SIGTERM, SIG_DFL)
    signal(SIGINT, SIG_DFL)
    exit(UpdateInstaller.apply(CommandLine.arguments[index + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
