import AppKit
import Foundation

final class UpdateStub: URLProtocol {
    static var requests = 0
    static var fail = false
    static var legacyOnly = false
    static var rateLimited = false
    static let version = "2026.10.21.100"
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let shouldFail = Self.fail
        let job = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if shouldFail {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            if Self.legacyOnly && self.request.url == UpdatePolicy.manifestURL {
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            if Self.rateLimited {
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 403, httpVersion: nil, headerFields: ["X-RateLimit-Remaining": "0"])!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            let v = Self.version
            let name = "wb2api-panel-\(v)-darwin-\(UpdatePolicy.architecture)-update.zip"
            let asset: [String: Any] = ["name": name, "browser_download_url": "https://github.com/\(UpdatePolicy.repository)/releases/download/v\(v)/\(name)", "digest": "sha256:" + String(repeating: "a", count: 64), "size": 1024, "state": "uploaded"]
            let body: [String: Any] = ["tag_name": "v"+v, "draft": false, "prerelease": false, "assets": [asset]]
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            let responseBody: [String: Any] = self.request.url == UpdatePolicy.manifestURL ? ["schema": 1, "release": body] : body
            self.client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: responseBody))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: job)
    }
    override func stopLoading() { work?.cancel() }
}

@main
struct ControllerTests {
    static func pump(_ duration: TimeInterval = 0.5) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() {
        _ = NSApplication.shared
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateStub.self]
        let controller = UpdateController(currentVersion: "dev", configuration: config)
        controller.check(manual: true)
        controller.check(manual: true)
        pump(0.03)
        require(UpdateStub.requests == 1, "duplicate checks must be coalesced")
        controller.cancelCurrent()
        pump()
        require(!controller.busy && controller.text.stringValue.contains("已取消"), "late response must not undo cancellation")
        controller.check(manual: true)
        pump()
        require(controller.button.title == "更新并重启", "available update must offer install")
        let offered = controller.text.stringValue
        UpdateStub.fail = true
        controller.check(manual: false)
        pump()
        require(controller.text.stringValue == offered && controller.button.title == "更新并重启", "silent errors must preserve a consistent offer")
        UpdateStub.fail = false
        UpdateStub.legacyOnly = true
        controller.check(manual: true)
        pump()
        require(controller.button.title == "更新并重启", "missing manifest must fall back to legacy release API")
        UpdateStub.rateLimited = true
        controller.check(manual: true)
        pump()
        require(controller.text.stringValue.contains("次数已达上限"), "rate limits need actionable feedback")
        UpdateStub.rateLimited = false
        UpdateStub.legacyOnly = false
        controller.showRollback()
        let rollback = controller.text.stringValue
        controller.check(manual: false)
        pump()
        require(controller.text.stringValue == rollback, "automatic check must not overwrite rollback notice")
        controller.showInstalled(UpdateStub.version)
        require(controller.text.stringValue.contains("已成功更新"), "successful handoff must be visible")
        controller.cancel()
        let requests = UpdateStub.requests
        controller.check(manual: true)
        pump()
        require(UpdateStub.requests == requests, "closed app cannot schedule new update work")
        print("PASS: 9 controller cancellation, concurrency and status checks")
    }
}
