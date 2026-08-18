import UIKit

@MainActor
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    nonisolated let proxyPort = 8888

    @Published private(set) var isRunning = false
    @Published var error: String?

    private let certificateStore = CertificateAuthorityStore()
    private var proxyHandle: UInt = 0
    private var coordinateRevision: UInt64 = 0

    private init() { RuntimeLogger.info("APP", "Proxy", "Initialized") }

    func start() async throws {
        guard !isRunning else { return }
        RuntimeLogger.info("APP", "Proxy.start", "Starting proxy at 127.0.0.1:8888")
        do {
            let authority = try certificateStore.ensure()
            let settings = WlocSettingsStore.load()
            let lat = settings.flatMap { $0.enabled ? $0.latitude : nil } ?? 0
            let lon = settings.flatMap { $0.enabled ? $0.longitude : nil } ?? 0
            let enabled = (settings?.enabled ?? false) ? CInt(1) : CInt(0)
            let accuracy = CInt(settings?.accuracy ?? 25)
            let motionEnabled = MotionSimulationStore.shared.isEnabled ? CInt(1) : CInt(0)
            if enabled != 0 {
                RuntimeLogger.info("APP", "Coordinate Conversion", "Proxy startup: restoring the last WGS-84 location")
            }
            let result: UInt = authority.certPEM.withCString { cp in
                authority.keyPEM.withCString { kp in
                    UInt(wloccore_startproxyv2(
                        UnsafeMutablePointer(mutating: cp),
                        UnsafeMutablePointer(mutating: kp),
                        CDouble(lat),
                        CDouble(lon),
                        enabled,
                        accuracy,
                        motionEnabled
                    ))
                }
            }
            guard result != 0 else { CoreBridge.flushLogs(category: "Proxy"); throw ProxyError.startFailed }
            proxyHandle = result
            isRunning = true
            error = nil
            BackgroundKeepAlive.shared.start()
            CoreBridge.flushLogs(category: "Proxy")
            RuntimeLogger.info("APP", "Proxy.start", "Started successfully")
        } catch {
            CoreBridge.flushLogs(category: "Proxy")
            RuntimeLogger.error("APP", "Proxy.start", "Failed to start", error: error)
            throw error
        }
    }

    func stop() {
        guard isRunning, proxyHandle != 0 else { return }
        _ = wloccore_stopproxy(proxyHandle)
        proxyHandle = 0; isRunning = false; error = nil
        BackgroundKeepAlive.shared.stop()
        CoreBridge.flushLogs(category: "Proxy")
    }

    @discardableResult
    func setCoords(lat: Double, lon: Double, enabled: Bool, accuracy: Int = 25) -> UInt64 {
        coordinateRevision &+= 1
        wloccore_setpatchconfig(
            CDouble(lat),
            CDouble(lon),
            enabled ? 1 : 0,
            CInt(accuracy),
            MotionSimulationStore.shared.isEnabled ? 1 : 0
        )
        RuntimeLogger.info("APP", "Proxy.coords", "Writing coordinates", details: [
            "revision": String(coordinateRevision),
            "enabled": String(enabled),
            "accuracy": String(accuracy)
        ])
        return coordinateRevision
    }

    func coordinateSnapshot(accuracy: Int = 25) -> ProxyCoordinateSnapshot {
        let coordinates = getCoords()
        return ProxyCoordinateSnapshot(
            latitude: coordinates.lat,
            longitude: coordinates.lon,
            enabled: coordinates.enabled,
            accuracy: accuracy,
            revision: coordinateRevision
        )
    }

    @discardableResult
    func setCoordsIfUnchanged(
        lat: Double,
        lon: Double,
        enabled: Bool,
        accuracy: Int = 25,
        expectedRevision: UInt64
    ) -> UInt64? {
        guard coordinateRevision == expectedRevision else {
            RuntimeLogger.info("APP", "Proxy.coords", "Skipped an outdated coordinate write", details: [
                "expectedRevision": String(expectedRevision),
                "currentRevision": String(coordinateRevision)
            ])
            return nil
        }
        return setCoords(lat: lat, lon: lon, enabled: enabled, accuracy: accuracy)
    }

    @discardableResult
    func restoreCoords(_ snapshot: ProxyCoordinateSnapshot, ifUnchangedSince revision: UInt64) -> Bool {
        guard coordinateRevision == revision else {
            RuntimeLogger.info("APP", "Proxy.coords", "Skipped restoration of old verification coordinates", details: [
                "verificationRevision": String(revision),
                "currentRevision": String(coordinateRevision)
            ])
            return false
        }
        setCoords(
            lat: snapshot.latitude,
            lon: snapshot.longitude,
            enabled: snapshot.enabled,
            accuracy: snapshot.accuracy
        )
        return true
    }

    func getCoords() -> (lat: Double, lon: Double, enabled: Bool) {
        let r = wloccore_getcoords()
        return (Double(r.r0), Double(r.r1), r.r2 != 0)
    }

    func applyMotionSimulation(_ enabled: Bool) {
        MotionSimulationStore.shared.setEnabled(enabled)
        let settings = WlocSettingsStore.load()
        wloccore_setpatchconfig(
            CDouble(settings?.latitude ?? 0),
            CDouble(settings?.longitude ?? 0),
            settings?.enabled == true ? 1 : 0,
            CInt(settings?.accuracy ?? 25),
            enabled ? 1 : 0
        )
        RuntimeLogger.info("APP", "Proxy.motion", "Motion-state simulation setting updated", details: [
            "enabled": String(enabled)
        ])
        CoreBridge.flushLogs(category: "Proxy")
    }

    func prepareCertificateDownloadURL() async -> URL? {
        do {
            if !isRunning { try await start() }
            guard let url = URL(string: "http://127.0.0.1:8888/cert") else {
                error = "The certificate download URL is invalid"
                return nil
            }
            error = nil
            return url
        } catch {
            self.error = "Failed to start the proxy: \(error.localizedDescription)"
            RuntimeLogger.error("APP", "Certificate", "Failed to prepare the certificate download", error: error)
            return nil
        }
    }

    nonisolated deinit {
        let h = proxyHandle
        if h != 0 { _ = wloccore_stopproxy(h) }
    }
}

struct ProxyCoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double
    let enabled: Bool
    let accuracy: Int
    let revision: UInt64
}

enum ProxyError: LocalizedError {
    case startFailed
    var errorDescription: String? { "The Go proxy failed to start" }
}
