import Foundation

@MainActor
protocol LocationActionProxying: AnyObject {
    var isRunning: Bool { get }
    func start() async throws
    func setCoords(lat: Double, lon: Double, enabled: Bool, accuracy: Int) -> UInt64
}

extension ProxyManager: LocationActionProxying {}

@MainActor
protocol LocationActionSettingsStoring: AnyObject {
    func load() -> WlocSettings?
    func save(_ settings: WlocSettings)
    func clear()
}

@MainActor
final class DeviceWlocSettingsStorage: LocationActionSettingsStoring {
    func load() -> WlocSettings? { WlocSettingsStore.load() }
    func save(_ settings: WlocSettings) { WlocSettingsStore.save(settings) }
    func clear() { WlocSettingsStore.clear() }
}

@MainActor
final class LocationActionCoordinator: ObservableObject {
    @Published private(set) var state: LocationActionState = .idle
    @Published private(set) var virtualLocationEnabled = false
    @Published private(set) var message = ""

    private let proxy: any LocationActionProxying
    private let settings: any LocationActionSettingsStoring

    init() {
        self.proxy = ProxyManager.shared
        self.settings = DeviceWlocSettingsStorage()
        self.virtualLocationEnabled = settings.load()?.enabled == true
    }

    init(proxy: any LocationActionProxying, settings: any LocationActionSettingsStoring) {
        self.proxy = proxy
        self.settings = settings
        self.virtualLocationEnabled = settings.load()?.enabled == true
    }

    func apply(_ favorite: FavoriteLocation) async -> Bool {
        guard beginApply() else { return false }
        do {
            if !proxy.isRunning { try await proxy.start() }
            guard !Task.isCancelled else {
                finishCancelledApply()
                return false
            }
            return commit(favorite)
        } catch {
            failApply(error)
            return false
        }
    }

    /// Commits a target after SetupCoordinator has completed verification.
    /// This method is synchronous on MainActor so selection revision validation
    /// and the final settings/proxy write cannot be interleaved by a newer map event.
    func applyVerified(_ favorite: FavoriteLocation) -> Bool {
        guard proxy.isRunning else {
            failApply(ProxyError.startFailed)
            return false
        }
        guard beginApply() else { return false }
        return commit(favorite)
    }

    func clear() {
        guard !state.isBusy else { return }
        _ = proxy.setCoords(lat: 0, lon: 0, enabled: false, accuracy: 25)
        settings.clear()
        state = .idle
        virtualLocationEnabled = false
        message = "Real location restored"
    }

    private func beginApply() -> Bool {
        guard !state.isBusy else { return false }
        state = .applyingLocation
        message = "Starting proxy…"
        return true
    }

    private func commit(_ favorite: FavoriteLocation) -> Bool {
        // WLOC 合约固定使用持久化的 WGS-84 值，不依赖当前地图地图坐标标准。
        let wgs = favorite.coordinatePair.wgs84
        let value = WlocSettings(
            longitude: wgs.longitude,
            latitude: wgs.latitude,
            accuracy: favorite.accuracy,
            enabled: true
        )
        settings.save(value)
        _ = proxy.setCoords(
            lat: wgs.latitude,
            lon: wgs.longitude,
            enabled: true,
            accuracy: favorite.accuracy
        )
        RuntimeLogger.info("APP", "Coordinate Conversion", "Set virtual location coordinates", details: [
            "WLOC coordinate system": CoordinateConverter.MapCoordinateSystem.wgs84.diagnosticName,
            "Current map coordinate system": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "Target region": CoordinateConverter.usesGCJ02ServiceArea(lat: wgs.latitude, lon: wgs.longitude) ? "GCJ-02 conversion region" : "Non-conversion region",
            "Source field": "coordinatePair.wgs84",
            "accuracy": String(favorite.accuracy)
        ])
        state = .idle
        virtualLocationEnabled = true
        message = "Virtual location enabled"
        return true
    }

    private func finishCancelledApply() {
        state = .idle
        message = "Location update cancelled"
    }

    private func failApply(_ error: Error) {
        virtualLocationEnabled = false
        message = "Failed to start"
        state = .failed(error.localizedDescription)
        RuntimeLogger.error("APP", "Location", "Failed to apply virtual location", error: error)
    }
}
