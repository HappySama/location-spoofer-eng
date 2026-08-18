import Foundation
import SwiftUI

@MainActor
final class SetupCoordinator: ObservableObject {
    @Published private(set) var trustState: CertificateTrustState = .checking
    @Published var message = ""
    @Published var isBrowsingWithoutTrust = false
    @Published var testLog = ""
    @Published private(set) var lastVerificationResult: VerificationResult?
    // 启动检测失败才弹引导页；检测通过则保持 false
    @Published var needsSetup = false
    @Published private(set) var setupStep: SetupStep = .proxy

    let certificateStore = CertificateAuthorityStore()
    let proxy = ProxyManager.shared
    private var isVerificationRunning = false

    init() { RuntimeLogger.info("APP", "Setup", "Initialized") }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var canModify: Bool { proxy.isRunning && trustState == .trusted }

    /// Local services are prepared before the setup UI so the environment test
    /// can distinguish Wi-Fi proxy configuration from CA trust failures.
    @discardableResult
    func prepareLocalServices() async -> Bool {
        do {
            _ = try certificateStore.ensure()
            if !proxy.isRunning { try await proxy.start() }
            message = ""
            return true
        } catch {
            message = "Local proxy initialization failed: \(error.localizedDescription)"
            RuntimeLogger.error("APP", "Startup", "Local service initialization failed", error: error)
            return false
        }
    }

    func applyVerificationResult(_ result: VerificationResult) {
        lastVerificationResult = result
        switch result {
        case .success:
            trustState = .trusted
            needsSetup = false
            message = "✓ Location environment is ready"
        case .certNotTrusted:
            trustState = .unavailable
            setupStep = .cert
            needsSetup = true
            message = "The CA certificate is not installed or trusted"
        case .verificationInProgress, .verificationSuperseded:
            break
        default:
            trustState = .unavailable
            setupStep = .proxy
            needsSetup = true
            message = "The Wi-Fi proxy is not configured correctly. Check 127.0.0.1:8888."
        }
    }

    func sceneDidBecomeActive() {}
    func browseMapWithoutSetup() { isBrowsingWithoutTrust = true; needsSetup = false }
    func completeSetup() { needsSetup = false }
    func requestModeSelection() {
        lastVerificationResult = nil
        message = ""
        setupStep = .mode
        needsSetup = true
    }
    func requestThirdPartyOnboarding() {
        lastVerificationResult = nil
        message = ""
        setupStep = .thirdPartyClient
        needsSetup = true
    }
    func requestThirdPartySetup(message: String) {
        lastVerificationResult = nil
        self.message = message
        setupStep = .thirdPartyImport
        needsSetup = true
    }
    func requestCertificateSetup() {
        lastVerificationResult = nil
        message = ""
        setupStep = .cert
        needsSetup = true
    }
    func requestSetup(message: String = "") {
        lastVerificationResult = nil
        self.message = message
        setupStep = .proxy
        needsSetup = true
    }

    // MARK: - Step-by-step verification test

    func runVerificationTest() async -> VerificationResult {
        guard !isVerificationRunning else { return .verificationInProgress }
        isVerificationRunning = true
        defer { isVerificationRunning = false }

        testLog = ""
        let log = { (msg: String) in self.testLog += msg + "\n" }

        log("======== Proxy Verification Test ========")
        log("App version: \(appVersion)")
        log("System version: iOS \(UIDevice.current.systemVersion)")
        log("")

        // Step A: Proxy running
        log("[Step A] Check whether the proxy is running…")
        log("  Address: 127.0.0.1:8888")
        let stepAStart = Date()
        if !proxy.isRunning {
            log("  ⚠ Proxy is not running; attempting to start it…")
            do { try await proxy.start() } catch {
                log("  ✗ Failed to start: \(error.localizedDescription)")
                return .proxyNotRunning
            }
            log("  ✓ Proxy started successfully")
        } else {
            log("  ✓ Proxy is already running")
        }
        collectProxyLogs(since: stepAStart, to: log)

        // Step B: Combined CA + WiFi proxy check (single request)
        log("")
        log("[Step B] Check the certificate and Wi-Fi proxy…")
        log("  Method: Request baidu.com/paopao-verify-<token>")
        log("  Interpretation: TLS error = certificate problem / mismatched response = proxy not configured / matching response = passed")
        let stepBStart = Date()
        let verifyToken = CoreBridge.refreshVerifyToken()
        guard !verifyToken.isEmpty else {
            log("  ✗ Unable to generate a verification token")
            return .certNotTrusted
        }
        do {
            let url = URL(string: "https://www.baidu.com/paopao-verify-\(verifyToken)")!
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let config = URLSessionConfiguration.ephemeral
            let (data, resp) = try await URLSession(configuration: config).data(for: req)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            if body == verifyToken {
                log("  ✓ Certificate is trusted and the Wi-Fi proxy is configured")
            } else {
                log("  ✗ Response mismatch: HTTP \(statusCode), \(data.count) bytes; Wi-Fi proxy is not configured")
                return .wifiProxyNotConfigured
            }
        } catch {
            let ns = error as NSError
            let msg = error.localizedDescription
            log("  ✗ Request failed [\(ns.domain) code=\(ns.code)]: \(msg)")
            if isCertificateTrustError(nsError: ns, message: msg) {
                log("  TLS/certificate validation failed; the CA certificate is not trusted")
                return .certNotTrusted
            }
            return .wifiProxyNotConfigured
        }
        collectProxyLogs(since: stepBStart, to: log)

        log("")
        log("======== Environment Check Passed ✓ ========")
        return .success
    }

    /// Classifies TLS trust failures without relying on localized error text alone.
    private func isCertificateTrustError(nsError: NSError, message: String) -> Bool {
        if nsError.domain == NSURLErrorDomain {
            let trustErrorCodes: Set<Int> = [
                -1200, // secure connection failed
                -1201, // server certificate has bad date
                -1202, // server certificate untrusted
                -1203, // server certificate has unknown root
                -1204, // server certificate not yet valid
                -1205, // client certificate rejected
                -1206, // client certificate required
            ]
            return trustErrorCodes.contains(nsError.code)
        }

        let normalized = message.lowercased()
        return normalized.contains("tls")
            || normalized.contains("ssl")
            || normalized.contains("certificate")
            || normalized.contains("证书")
    }

    /// 拉取 Go 代理的详细日志（CONNECT/请求/上游响应/改写结果）到 testLog
    private func collectProxyLogs(since date: Date, to log: (String) -> Void) {
        CoreBridge.flushLogs(category: "Proxy")
        let entries = RuntimeLogStore.loadAll(limit: 200)
        let proxyEntries = entries.filter {
            $0.source == "CORE" && $0.category == "Proxy" && $0.timestamp >= date
        }
        guard !proxyEntries.isEmpty else { return }
        log("  --- Proxy Logs ---")
        for e in proxyEntries {
            log("  " + e.message)
        }
    }
}
