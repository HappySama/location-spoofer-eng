import Foundation
import UIKit

enum SystemSettingsDestination {
    case appPermissions
    case general
    case wifi
    case locationServices

    var preferredURL: URL? {
        let value: String
        switch self {
        case .appPermissions:
            value = UIApplication.openSettingsURLString
        case .general:
            value = "App-Prefs:General"
        case .wifi:
            value = "App-Prefs:WIFI"
        case .locationServices:
            value = "App-Prefs:Privacy&path=LOCATION"
        }
        return URL(string: value)
    }

    var manualPath: String {
        switch self {
        case .appPermissions:
            return "Open Settings manually, select this app, and check its location permission."
        case .general:
            return "Open Settings → General manually."
        case .wifi:
            return "Open Settings → Wi-Fi manually, then open the details for the connected network."
        case .locationServices:
            return "Open Settings → Privacy & Security → Location Services manually."
        }
    }
}

@MainActor
enum SystemSettingsNavigator {
    static func open(
        _ destination: SystemSettingsDestination,
        completion: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        let appSettingsURL = URL(string: UIApplication.openSettingsURLString)
        let preferredURL = destination.preferredURL

        openURL(preferredURL) { openedPreferred in
            guard !openedPreferred else {
                completion(nil)
                return
            }
            guard preferredURL != appSettingsURL else {
                completion(destination.manualPath)
                return
            }
            openURL(appSettingsURL) { openedFallback in
                completion(openedFallback ? nil : destination.manualPath)
            }
        }
    }

    private static func openURL(_ url: URL?, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let url else {
            completion(false)
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            completion(opened)
        }
    }
}
