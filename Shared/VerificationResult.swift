import Foundation

/// 环境验证结果，由 SetupCoordinator 统一路由到对应引导页面。
enum VerificationResult: Equatable, Identifiable {
    case success
    case proxyNotRunning
    case verificationInProgress
    case verificationSuperseded
    case certNotTrusted
    case wifiProxyNotConfigured
    case coordinateWriteFailed(String)
    case patchFailed(String)

    var id: String {
        switch self {
        case .success: return "Success"
        case .proxyNotRunning: return "Proxy Not Running"
        case .verificationInProgress: return "Verification Already in Progress"
        case .verificationSuperseded: return "Verification Superseded by a New Location"
        case .certNotTrusted: return "Certificate Not Trusted"
        case .wifiProxyNotConfigured: return "Wi-Fi Proxy Not Configured"
        case .coordinateWriteFailed: return "Coordinate Write Failed"
        case .patchFailed: return "Location Modification Test Failed"
        }
    }

    var isSuccess: Bool { self == .success }

}
