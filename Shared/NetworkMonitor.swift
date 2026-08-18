import Network
import Foundation
import SystemConfiguration.CaptiveNetwork

enum WiFiChangeReason: String {
    case reconnected = "Wi-Fi reconnected"
    case interfaceChanged = "Network interface changed to Wi-Fi"
    case ssidChanged = "SSID changed"
}

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isSatisfied = true
    @Published private(set) var isWiFiEnabled = true
    @Published private(set) var currentSSID: String?

    /// Wi-Fi 重连、接口切换或 SSID 变化时触发。调用方必须在离开页面时移除订阅。
    private var wifiChangeHandlers: [UUID: @MainActor (WiFiChangeReason) -> Void] = [:]

    private let monitor = NWPathMonitor()
    private var ssidTimer: Timer?
    private var wasSatisfied = true
    private var wasWiFiEnabled = true
    private var hasReceivedInitialPath = false
    private var lastKnownSSID: String?

    private init() {
        let initialSSID = Self.fetchSSID()
        currentSSID = initialSSID
        lastKnownSSID = initialSSID
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self else { return }
                let reason: WiFiChangeReason?
                if !self.hasReceivedInitialPath {
                    // NWPathMonitor 的首次回调只是状态基线，不是网络切换。
                    self.hasReceivedInitialPath = true
                    reason = nil
                } else if satisfied && wifi && !self.wasSatisfied {
                    reason = .reconnected
                } else if satisfied && wifi && !self.wasWiFiEnabled {
                    // 蜂窝网络和 Wi-Fi 都可能是 satisfied，不能只比较 status。
                    reason = .interfaceChanged
                } else {
                    reason = nil
                }
                self.wasSatisfied = satisfied
                self.wasWiFiEnabled = wifi
                self.isSatisfied = satisfied
                self.isWiFiEnabled = wifi
                if let reason {
                    self.notifyWiFiChanged(reason: reason)
                }
            }
        }
        monitor.start(queue: .main)
        startSSIDPolling()
    }

    /// Registers a Wi-Fi-change observer and returns a token that must be removed.
    @discardableResult
    func observeWiFiChanges(_ handler: @escaping @MainActor (WiFiChangeReason) -> Void) -> UUID {
        let token = UUID()
        wifiChangeHandlers[token] = handler
        return token
    }

    func removeWiFiChangeObserver(_ token: UUID) {
        wifiChangeHandlers.removeValue(forKey: token)
    }

    private func notifyWiFiChanged(reason: WiFiChangeReason) {
        for handler in wifiChangeHandlers.values {
            handler(reason)
        }
    }

    private func startSSIDPolling() {
        ssidTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ssid = Self.fetchSSID()
                self.currentSSID = ssid
                guard let ssid else { return }
                guard let previousSSID = self.lastKnownSSID else {
                    // 首次取得 SSID 只是建立基线，不能当作用户切换了 Wi-Fi。
                    self.lastKnownSSID = ssid
                    return
                }
                if ssid != previousSSID {
                    self.lastKnownSSID = ssid
                    self.notifyWiFiChanged(reason: .ssidChanged)
                }
            }
        }
    }

    static func fetchSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for iface in interfaces {
            if let info = CNCopyCurrentNetworkInfo(iface as CFString) as? [String: Any],
               let ssid = info[kCNNetworkInfoKeySSID as String] as? String {
                return ssid
            }
        }
        return nil
    }
}
