import Foundation

struct ThirdPartyProxySettingsResponse: Decodable, Equatable {
    let success: Bool
    let longitude: Double?
    let latitude: Double?
    let accuracy: Int?
    let error: String?
    let motionSimulationEnabled: Bool?
}

struct ThirdPartyProxyVersionResponse: Decodable, Equatable {
    let success: Bool
    let moduleVersion: String
    let protocolVersion: Int
    let capabilities: Set<String>

    static let requiredCapabilities: Set<String> = [
        "wifi", "cellTower", "arpc", "marker", "synthetic", "bare", "motionSimulation"
    ]

    var isCompatible: Bool {
        success && protocolVersion >= 1 && capabilities.isSuperset(of: Self.requiredCapabilities)
    }
}

enum ThirdPartyProxyConnectionState: Equatable {
    case unknown
    case connected(active: Bool)
    case failed(String)
}

enum ThirdPartyProxyError: LocalizedError, Equatable {
    case invalidResponse
    case moduleNotIntercepted
    case rejected(String)
    case coordinateMismatch
    case network(String)
    case moduleOutdated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The third-party proxy returned unrecognized data"
        case .moduleNotIntercepted:
            return "The request was not intercepted by the third-party proxy module. Check the module, MITM settings, and proxy connection."
        case .rejected(let message):
            return message
        case .coordinateMismatch:
            return "The coordinates saved by the third-party proxy do not match the selected location"
        case .network(let message):
            return "Third-party proxy request failed: \(message)"
        case .moduleOutdated:
            return "The module is outdated. Reimport the latest version."
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .moduleOutdated:
            return "Delete the old module, then copy and import the latest version"
        default:
            return "Check the module, MITM settings, certificate, and proxy/VPN connection"
        }
    }

    static func recoverySuggestion(for error: Error) -> String {
        (error as? Self)?.recoverySuggestion
            ?? "Check the module, MITM settings, certificate, and proxy/VPN connection"
    }
}

protocol ThirdPartyProxyRequesting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ThirdPartyProxyRequesting {}

@MainActor
final class ThirdPartyProxyManager: ObservableObject {
    static let shared = ThirdPartyProxyManager()
    static let interceptionHostnames = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com"
    ]
    static let interceptionHostnamesText = interceptionHostnames.joined(separator: ", ")
    static let configurationEndpoint = URL(string: "https://gs-loc.apple.com/wloc-settings/save")!
    static let versionEndpoint = URL(string: "https://gs-loc.apple.com/wloc-settings/version")!

    @Published private(set) var connectionState: ThirdPartyProxyConnectionState = .unknown
    @Published private(set) var activeSettings: ThirdPartyProxySettingsResponse?
    @Published private(set) var moduleUpdateRecommended = false
    @Published private(set) var isRequesting = false
    private let requester: any ThirdPartyProxyRequesting

    init(requester: (any ThirdPartyProxyRequesting)? = nil) {
        if let requester {
            self.requester = requester
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            self.requester = URLSession(configuration: configuration)
        }
    }

    func query() async throws -> ThirdPartyProxySettingsResponse {
        let response = try await perform(action: .query)
        let active = try validatedQueryState(response)
        if active {
            activeSettings = response
            connectionState = .connected(active: true)
        } else {
            activeSettings = nil
            connectionState = .connected(active: false)
        }
        return response
    }

    func save(_ favorite: FavoriteLocation) async throws -> ThirdPartyProxySettingsResponse {
        let wgs84 = favorite.coordinatePair.wgs84
        let response = try await perform(action: .save(
            latitude: wgs84.latitude,
            longitude: wgs84.longitude,
            accuracy: favorite.accuracy,
            motionEnabled: MotionSimulationStore.shared.isEnabled
        ))
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? "The third-party proxy rejected the coordinate save request")
        }
        guard let latitude = response.latitude,
              let longitude = response.longitude,
              abs(latitude - wgs84.latitude) <= 0.000_001,
              abs(longitude - wgs84.longitude) <= 0.000_001 else {
            throw ThirdPartyProxyError.coordinateMismatch
        }
        activeSettings = response
        connectionState = .connected(active: true)
        RuntimeLogger.info("APP", "ThirdPartyProxy", "Third-party proxy saved WGS-84 coordinates", details: [
            "Coordinate system": "WGS-84",
            "Source field": "coordinatePair.wgs84",
            "accuracy": String(favorite.accuracy)
        ])
        return response
    }

    func updateMotionSimulation(_ enabled: Bool) async throws -> ThirdPartyProxySettingsResponse {
        guard let current = activeSettings,
              let latitude = current.latitude,
              let longitude = current.longitude else {
            throw ThirdPartyProxyError.rejected("Third-party virtual location is not enabled")
        }
        guard await refreshAdvancedFeatureAvailability() else {
            throw ThirdPartyProxyError.moduleOutdated
        }
        let response = try await perform(action: .save(
            latitude: latitude,
            longitude: longitude,
            accuracy: current.accuracy ?? 25,
            motionEnabled: enabled
        ))
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? "The third-party proxy rejected the motion-state update")
        }
        activeSettings = response
        return response
    }

    func validateConnection() async throws -> ThirdPartyProxySettingsResponse {
        try await query()
    }

    func validateVersion() async throws -> ThirdPartyProxyVersionResponse {
        guard !isRequesting else {
            throw ThirdPartyProxyError.rejected("Another third-party proxy request is already running")
        }
        isRequesting = true
        defer { isRequesting = false }

        var request = URLRequest(url: Self.versionEndpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        do {
            let (data, response) = try await requester.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let version = try? JSONDecoder().decode(ThirdPartyProxyVersionResponse.self, from: data),
                  version.isCompatible else {
                throw ThirdPartyProxyError.moduleOutdated
            }
            RuntimeLogger.info("APP", "ThirdPartyProxy", "Third-party module version check passed", details: [
                "Module version": version.moduleVersion,
                "Protocol version": String(version.protocolVersion),
                "Capabilities": version.capabilities.sorted().joined(separator: ",")
            ])
            return version
        } catch let error as ThirdPartyProxyError {
            throw error
        } catch {
            throw ThirdPartyProxyError.network(error.localizedDescription)
        }
    }

    @discardableResult
    func refreshAdvancedFeatureAvailability() async -> Bool {
        do {
            _ = try await validateVersion()
            moduleUpdateRecommended = false
            return true
        } catch {
            moduleUpdateRecommended = true
            RuntimeLogger.warning(
                "APP",
                "ThirdPartyProxy",
                "Third-party module does not support advanced features",
                details: [
                    "Version check": error.localizedDescription,
                    "Suggested fix": "Basic coordinate spoofing still works; update the module to use motion-state simulation"
                ]
            )
            return false
        }
    }

    func clear() async throws {
        let response = try await perform(action: .clear)
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? "The third-party proxy failed to clear its coordinates")
        }
        activeSettings = nil
        connectionState = .connected(active: false)
        RuntimeLogger.info("APP", "ThirdPartyProxy", "Third-party proxy coordinates cleared")
    }

    private func validatedQueryState(_ response: ThirdPartyProxySettingsResponse) throws -> Bool {
        if response.success,
           response.latitude != nil,
           response.longitude != nil {
            return true
        }
        if response.error?.contains("无已保存") == true || response.error?.localizedCaseInsensitiveContains("no saved") == true {
            return false
        }
        throw ThirdPartyProxyError.rejected(response.error ?? "Third-party proxy query failed")
    }

    private enum Action {
        case query
        case save(latitude: Double, longitude: Double, accuracy: Int, motionEnabled: Bool)
        case clear
    }

    private func perform(action: Action) async throws -> ThirdPartyProxySettingsResponse {
        guard !isRequesting else {
            throw ThirdPartyProxyError.rejected("Another third-party proxy request is already running")
        }
        isRequesting = true
        defer { isRequesting = false }

        var components = URLComponents(url: Self.configurationEndpoint, resolvingAgainstBaseURL: false)!
        switch action {
        case .query:
            components.queryItems = [URLQueryItem(name: "action", value: "query")]
        case .clear:
            components.queryItems = [URLQueryItem(name: "action", value: "clear")]
        case .save(let latitude, let longitude, let accuracy, let motionEnabled):
            components.queryItems = [
                URLQueryItem(name: "lon", value: String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), longitude)),
                URLQueryItem(name: "lat", value: String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), latitude)),
                URLQueryItem(name: "acc", value: String(accuracy)),
                URLQueryItem(
                    name: "motion",
                    value: motionEnabled ? "1" : "0"
                )
            ]
        }
        guard let url = components.url else { throw ThirdPartyProxyError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, urlResponse) = try await requester.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse, http.statusCode == 200 else {
                throw ThirdPartyProxyError.moduleNotIntercepted
            }
            guard let response = try? JSONDecoder().decode(ThirdPartyProxySettingsResponse.self, from: data) else {
                throw ThirdPartyProxyError.moduleNotIntercepted
            }

            return response
        } catch let error as ThirdPartyProxyError {
            connectionState = .failed(error.localizedDescription)
            RuntimeLogger.error("APP", "ThirdPartyProxy", "Third-party proxy request failed", error: error)
            throw error
        } catch {
            let mapped = ThirdPartyProxyError.network(error.localizedDescription)
            connectionState = .failed(mapped.localizedDescription)
            RuntimeLogger.error("APP", "ThirdPartyProxy", "Third-party proxy request failed", error: error)
            throw mapped
        }
    }
}

enum ThirdPartyProxyClient: String, CaseIterable, Identifiable {
    static let moduleSubscriptionVersion = "1.0.0"

    case shadowrocket
    case surge
    case quantumultX
    case loon
    case stash
    case egern

    var id: String { rawValue }

    var name: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .surge: return "Surge"
        case .quantumultX: return "Quantumult X"
        case .loon: return "Loon"
        case .stash: return "Stash"
        case .egern: return "Egern"
        }
    }

    var verificationText: String? {
        self == .shadowrocket ? nil : "Configuration provided but not yet verified"
    }

    var moduleFileName: String {
        switch self {
        case .shadowrocket: return "wloc.module"
        case .surge, .egern: return "wloc.sgmodule"
        case .quantumultX: return "wloc.conf"
        case .loon: return "wloc.lpx"
        case .stash: return "wloc.stoverride"
        }
    }

    @MainActor
    var subscriptionURL: URL {
        let url: String
        let directory = ThirdPartyModuleSourceStore.shared.useMirror
            ? "Resources/ThirdPartyProxyModules"
            : "ThirdParty/WlocScripts/modules/direct"
        let prefix = ThirdPartyModuleSourceStore.shared.useMirror
            ? "https://gh-proxy.org/https://raw.githubusercontent.com/xweiba/location-spoofer/main/"
            : "https://raw.githubusercontent.com/xweiba/location-spoofer/main/"
        switch self {
        case .surge, .egern:
            url = "\(prefix)\(directory)/wloc.sgmodule"
        case .quantumultX:
            url = "\(prefix)\(directory)/wloc.conf"
        case .loon:
            url = "\(prefix)\(directory)/wloc.lpx"
        case .stash:
            url = "\(prefix)\(directory)/wloc.stoverride"
        case .shadowrocket:
            url = "\(prefix)\(directory)/wloc.module"
        }
        return URL(string: "\(url)?v=\(Self.moduleSubscriptionVersion)")!
    }

    var launchURL: URL? {
        switch self {
        case .shadowrocket: return URL(string: "shadowrocket://")
        case .surge: return URL(string: "surge://")
        case .quantumultX: return URL(string: "quantumult-x://")
        case .loon: return URL(string: "loon://")
        case .stash: return URL(string: "stash://")
        case .egern: return URL(string: "egern://")
        }
    }
}

@MainActor
final class ThirdPartyProxyClientStore: ObservableObject {
    static let shared = ThirdPartyProxyClientStore()

    private enum Key {
        static let selectedClient = "selectedThirdPartyProxyClient"
    }

    @Published private(set) var selectedClient: ThirdPartyProxyClient
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        selectedClient = defaults.string(forKey: Key.selectedClient)
            .flatMap(ThirdPartyProxyClient.init(rawValue:)) ?? .shadowrocket
    }

    func select(_ client: ThirdPartyProxyClient) {
        selectedClient = client
        defaults.set(client.rawValue, forKey: Key.selectedClient)
    }
}
