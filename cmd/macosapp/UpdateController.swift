import AppKit
import Foundation

final class UpdateController: NSObject {
    let text = NSTextField(wrappingLabelWithString: "")
    lazy var button: NSButton = {
        let b = NSButton(title: "检查更新", target: self, action: #selector(clicked))
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }()
    lazy var cancelButton: NSButton = {
        let b = NSButton(title: "取消", target: self, action: #selector(cancelCurrent))
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.isHidden = true
        return b
    }()
    lazy var releaseButton: NSButton = {
        let b = NSButton(title: "发布说明", target: self, action: #selector(openReleases))
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }()
    lazy var logButton: NSButton = {
        let b = NSButton(title: "更新日志", target: self, action: #selector(openUpdateLog))
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }()
    let progress = NSProgressIndicator()
    var onInstall: ((URL, AvailableUpdate) -> Void)?
    private(set) var busy = false
    private var available: AvailableUpdate?
    private var operation: UpdateOperation?
    private var metadataTask: URLSessionDataTask?
    private var download: URLSessionDownloadTask?
    private var progressTimer: Timer?
    private var periodic: Timer?
    private var lastCheck = Date.distantPast
    private let current: String
    private let session: URLSession
    private var closed = false
    private var preserveNotice = false

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
         configuration: URLSessionConfiguration = .ephemeral) {
        current = currentVersion
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
        super.init()
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.isHidden = true
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.maximumNumberOfLines = 3
        text.stringValue = "当前版本：\(current == "dev" ? "dev（本地构建）" : "v" + current)"
    }

    func startChecking() {
        check(manual: false)
        periodic = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }
    func focused() {
        if Date().timeIntervalSince(lastCheck) > 3600 { check(manual: false) }
    }
    func cancel() {
        closed = true
        operation?.cancel()
        metadataTask?.cancel()
        download?.cancel()
        progressTimer?.invalidate()
        periodic?.invalidate()
        session.invalidateAndCancel()
    }
    @objc func cancelCurrent() {
        guard !cancelButton.isHidden, busy else { return }
        operation?.cancel()
        operation = nil
        metadataTask?.cancel()
        metadataTask = nil
        download?.cancel()
        download = nil
        progressTimer?.invalidate()
        busy = false
        show("已取消，当前安装未改变。")
        refreshButton()
    }
    @objc private func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdatePolicy.repository)/releases")!)
    }
    @objc private func openUpdateLog() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WorkBuddy2API/data")
        let log = folder.appendingPathComponent("updater.log")
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
        else { show("暂无安装日志；下载并安装后会记录到 updater.log。") }
    }
    private func show(_ message: String) {
        text.stringValue = "当前版本：\(current == "dev" ? "dev" : "v" + current) · \(message)"
    }
    private func refreshButton() {
        button.title = available == nil ? "检查更新" : "更新并重启"
        button.isEnabled = !busy && !closed
        cancelButton.isHidden = !busy || operation == nil
        progress.isHidden = !busy
        if !busy { progress.stopAnimation(nil) }
    }
    @objc private func clicked() {
        if let update = available { install(update) } else { check(manual: true) }
    }

    private func fetch(_ ticket: UpdateOperation, legacy: Bool = false,
                       _ completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        let url = legacy ? UpdatePolicy.endpoint : UpdatePolicy.manifestURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WorkBuddy2API-Updater", forHTTPHeaderField: "User-Agent")
        metadataTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if !legacy, (response as? HTTPURLResponse)?.statusCode == 404 {
                DispatchQueue.main.async {
                    if ticket.isActive { self.fetch(ticket, legacy: true, completion) }
                }
                return
            }
            let result: Result<ReleaseInfo, Error> = Result {
                if let error = error { throw error }
                guard let response = response as? HTTPURLResponse else { throw UpdateFailure("无法连接更新服务器。") }
                if response.statusCode == 429 || (response.statusCode == 403 && response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                    throw UpdateFailure("GitHub 检查次数已达上限，请稍后重试或点击“发布说明”。")
                }
                guard response.statusCode == 200, let data = data, data.count < 2 * 1024 * 1024 else {
                    throw UpdateFailure("无法读取更新信息，请检查网络或稍后重试。")
                }
                if legacy { return try JSONDecoder().decode(ReleaseInfo.self, from: data) }
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                guard manifest.schema == 1 else { throw UpdateFailure("更新清单格式不受支持，请从发布页安装。") }
                return manifest.release
            }
            DispatchQueue.main.async {
                guard ticket.isActive else { return }
                completion(result)
            }
        }
        metadataTask?.resume()
    }

    func check(manual: Bool) {
        guard !busy, !closed, manual || !preserveNotice else { return }
        if manual { preserveNotice = false }
        let ticket = UpdateOperation()
        operation = ticket
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        busy = true
        lastCheck = Date()
        refreshButton()
        if manual { show("正在检查…") }
        fetch(ticket) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            self.operation = nil
            do {
                self.available = try UpdatePolicy.select(result.get(), current: self.current)
                if let update = self.available {
                    self.show("发现 v\(update.version)，点击更新后会自动重启。")
                } else { self.show("已是最新版本") }
            } catch {
                // A failed automatic check must not erase a previously offered
                // update while leaving its text visible. Installation rechecks it.
                if manual { self.available = nil; self.show(error.localizedDescription) }
                else { NSLog("Update check: %@", error.localizedDescription) }
            }
            self.refreshButton()
        }
    }

    private func install(_ expected: AvailableUpdate) {
        guard !busy, !closed else { return }
        let target = Bundle.main.bundleURL.standardizedFileURL
        guard target.lastPathComponent == "WorkBuddy2API.app",
              (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            show("安装目录不可写，请先将应用移到可写的“应用程序”目录。")
            return
        }
        let ticket = UpdateOperation()
        operation = ticket
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        busy = true
        refreshButton()
        show("正在确认更新版本…")
        // Bind installation to exactly the version and asset the user selected.
        fetch(ticket) { [weak self] result in
            guard let self = self else { return }
            do {
                guard try UpdatePolicy.select(result.get(), current: self.current) == expected else {
                    throw UpdateFailure("发布内容已变化，请重新检查更新。")
                }
                self.download(expected, target: target, ticket: ticket)
            } catch { self.failed(error) }
        }
    }

    private func failed(_ error: Error) {
        busy = false
        operation = nil
        available = nil
        download = nil
        progressTimer?.invalidate()
        progressTimer = nil
        show(error.localizedDescription)
        refreshButton()
    }

    private func download(_ update: AvailableUpdate, target: URL, ticket: UpdateOperation) {
        show("正在下载 v\(update.version)…")
        progress.isIndeterminate = false
        progress.doubleValue = 0
        let task = session.downloadTask(with: URL(string: update.asset.browser_download_url)!) { [weak self] file, response, error in
            guard let self = self else { return }
            // URLSession removes its temporary file when this callback returns.
            // Perform validation and staging on this background delegate queue.
            var workspace: URL?
            do {
                try ticket.check()
                if let error = error { throw error }
                guard let file = file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateFailure("更新包下载失败。")
                }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size == update.asset.size, size <= UpdatePolicy.maxArchiveSize else {
                    throw UpdateFailure("更新包大小校验失败。")
                }
                DispatchQueue.main.async {
                    guard ticket.isActive else { return }
                    self.progressTimer?.invalidate()
                    self.progress.isIndeterminate = true
                    self.progress.startAnimation(nil)
                    self.show("下载完成，正在校验并准备安装…")
                }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                try UpdatePolicy.verifyArchive(data, asset: update.asset)
                try ticket.check()
                let directory = target.deletingLastPathComponent()
                    .appendingPathComponent(".WorkBuddy2API-update-" + UUID().uuidString, isDirectory: true)
                workspace = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try UpdatePolicy.run("/usr/bin/ditto", ["-x", "-k", file.path, directory.path])
                try ticket.check()
                try UpdatePolicy.validateBundle(directory.appendingPathComponent("WorkBuddy2API.app"), version: update.version)
                try ticket.check()
                DispatchQueue.main.async {
                    guard ticket.isActive, !self.closed else {
                        try? FileManager.default.removeItem(at: directory)
                        return
                    }
                    self.operation = nil
                    self.cancelButton.isHidden = true
                    self.download = nil
                    self.show("校验通过，正在停止服务并安装…")
                    self.onInstall?(directory, update)
                }
            } catch {
                if let workspace = workspace { try? FileManager.default.removeItem(at: workspace) }
                DispatchQueue.main.async { if ticket.isActive { self.failed(error) } }
            }
        }
        download = task
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self, weak task] _ in
            guard let self = self, let task = task, ticket.isActive else { return }
            if task.countOfBytesReceived > UpdatePolicy.maxArchiveSize { task.cancel(); return }
            let percent = min(100, Int(task.countOfBytesReceived * 100 / Int64(update.asset.size)))
            self.progress.doubleValue = Double(percent)
            self.show("正在下载 v\(update.version)：\(percent)%")
        }
        task.resume()
    }

    func showInstalled(_ version: String) {
        preserveNotice = true
        operation?.cancel()
        busy = false
        operation = nil
        refreshButton()
        show("已成功更新至 v\(version)，旧版备份已保留。")
    }

    func installationFailed(_ error: Error) { failed(error) }
    func showRollback() {
        preserveNotice = true
        operation?.cancel()
        busy = false
        operation = nil
        refreshButton()
        show("新版启动失败，已恢复旧版。详情见 data/updater.log。")
    }
}
