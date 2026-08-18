import Combine
import CoreLocation
import Foundation

@MainActor
protocol RealtimeLocationDriving: AnyObject {
    var location: CLLocation? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var delegate: CLLocationManagerDelegate? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

@MainActor
final class CoreLocationDriver: RealtimeLocationDriving {
    private let manager: CLLocationManager

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    var location: CLLocation? { manager.location }
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var delegate: CLLocationManagerDelegate? {
        get { manager.delegate }
        set { manager.delegate = newValue }
    }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }
    func startUpdatingLocation() { manager.startUpdatingLocation() }
    func stopUpdatingLocation() { manager.stopUpdatingLocation() }
}

@MainActor
final class RealtimeLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RealtimeLocationManager(driver: CoreLocationDriver())

    @Published private(set) var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isRequesting = false

    private enum RequestPhase: Equatable {
        case awaitingAuthorization
        case oneShot
        case continuousFallback
    }

    private struct ActiveRequest {
        let id: UInt64
        var startedAt: Date?
        let continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>
        var phase: RequestPhase
    }

    private let driver: RealtimeLocationDriving
    private let oneShotTimeoutNanoseconds: UInt64
    private let fallbackTimeoutNanoseconds: UInt64
    private let cacheMaxAge: TimeInterval = 20
    private var nextRequestID: UInt64 = 0
    private var activeRequest: ActiveRequest?
    private var timeoutTask: Task<Void, Never>?

    init(
        driver: RealtimeLocationDriving,
        oneShotTimeoutNanoseconds: UInt64 = 1_500_000_000,
        fallbackTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.driver = driver
        self.oneShotTimeoutNanoseconds = oneShotTimeoutNanoseconds
        self.fallbackTimeoutNanoseconds = fallbackTimeoutNanoseconds
        authorizationStatus = driver.authorizationStatus
        super.init()
        driver.delegate = self
        if let cached = driver.location, Self.isValid(cached) {
            location = cached
        }
    }

    convenience init(driver: RealtimeLocationDriving, timeoutNanoseconds: UInt64) {
        self.init(
            driver: driver,
            oneShotTimeoutNanoseconds: timeoutNanoseconds,
            fallbackTimeoutNanoseconds: timeoutNanoseconds
        )
    }

    func requestLocation() async -> CLLocationCoordinate2D? {
        guard activeRequest == nil else {
            RuntimeLogger.warning("APP", "Real-Time Location", "Ignored duplicate CLLocationManager request", details: [
                "Active request ID": activeRequest.map { String($0.id) } ?? "nil",
                "Active phase": activeRequest.map { phaseName($0.phase) } ?? "nil"
            ])
            return nil
        }

        authorizationStatus = driver.authorizationStatus
        RuntimeLogger.info("APP", "Real-Time Location", "CLLocationManager request received", details: [
            "Authorization": authorizationName(authorizationStatus),
            "In-memory cache available": String(location != nil),
            "System cache available": String(driver.location != nil)
        ])
        guard authorizationStatus != .denied, authorizationStatus != .restricted else {
            RuntimeLogger.warning("APP", "Real-Time Location", "Authorization status does not permit location access", details: [
                "Authorization": authorizationName(authorizationStatus)
            ])
            return nil
        }

        if let cached = freshestCachedLocation() {
            location = cached
            RealtimeLocationTrace.log("Using a fresh CLLocationManager cache sample", location: cached, details: [
                "Source": "manager-memory-or-system",
                "Maximum cache age (seconds)": String(Int(cacheMaxAge))
            ])
            return cached.coordinate
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        isRequesting = true
        RuntimeLogger.info("APP", "Real-Time Location", "Created CLLocationManager request", details: [
            "requestID": String(requestID),
            "Authorization": authorizationName(authorizationStatus),
            "Initial phase": "awaitingAuthorization"
        ])

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                activeRequest = ActiveRequest(
                    id: requestID,
                    startedAt: nil,
                    continuation: continuation,
                    phase: .awaitingAuthorization
                )

                if authorizationStatus == .notDetermined {
                    RuntimeLogger.info("APP", "Real-Time Location", "Requesting foreground location authorization", details: [
                        "requestID": String(requestID)
                    ])
                    scheduleTimeout(for: requestID, nanoseconds: fallbackTimeoutNanoseconds)
                    driver.requestWhenInUseAuthorization()
                } else {
                    beginOneShot(for: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishRequest(id: requestID, coordinate: nil)
            }
        }
    }

    func startUpdating() {
        if authorizationStatus == .notDetermined {
            driver.requestWhenInUseAuthorization()
        }
        driver.startUpdatingLocation()
    }

    func stopUpdating() {
        driver.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
        authorizationStatus = driver.authorizationStatus
        RuntimeLogger.info("APP", "Real-Time Location", "Location authorization changed", details: [
            "Authorization": authorizationName(authorizationStatus),
            "requestID": activeRequest.map { String($0.id) } ?? "nil",
            "Phase": activeRequest.map { phaseName($0.phase) } ?? "idle"
        ])
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if let request = activeRequest, request.phase == .awaitingAuthorization {
                beginOneShot(for: request.id)
            }
        case .denied, .restricted:
            finishRequest(id: activeRequest?.id, coordinate: nil)
        case .notDetermined:
            break
        @unknown default:
            finishRequest(id: activeRequest?.id, coordinate: nil)
        }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
        RuntimeLogger.info("APP", "Real-Time Location", "CLLocationManager returned a batch of samples", details: [
            "Sample count": String(locations.count),
            "requestID": activeRequest.map { String($0.id) } ?? "nil",
            "Phase": activeRequest.map { phaseName($0.phase) } ?? "idle"
        ])
        for (index, candidate) in locations.enumerated() {
            let valid = Self.isValid(candidate)
            let freshEnough = activeRequest?.startedAt.map {
                candidate.timestamp >= $0.addingTimeInterval(-1)
            } ?? false
            RealtimeLocationTrace.log(
                valid ? "Inspecting CLLocationManager sample" : "Rejected CLLocationManager sample: invalid coordinates or accuracy",
                location: candidate,
                details: [
                    "Batch index": String(index),
                    "Basic validation passed": String(valid),
                    "Within current request window": String(freshEnough)
                ],
                level: valid ? .info : .warning
            )
        }
        let validLocations = locations.filter(Self.isValid)
        if let latestValid = validLocations.last {
            location = latestValid
        }

        guard let request = activeRequest,
              let startedAt = request.startedAt,
              request.phase != .awaitingAuthorization,
              let latest = validLocations.last(where: {
                  $0.timestamp >= startedAt.addingTimeInterval(-1)
              }) else {
            if let request = activeRequest, request.phase != .awaitingAuthorization {
                RuntimeLogger.warning("APP", "Real-Time Location", "This batch contains no sample that can complete the current request", details: [
                    "requestID": String(request.id),
                    "Phase": phaseName(request.phase),
                    "Valid sample count": String(validLocations.count)
                ])
            }
            return
        }
        RealtimeLocationTrace.log("Accepted CLLocationManager sample and completed the request", location: latest, details: [
            "requestID": String(request.id),
            "Phase": phaseName(request.phase)
        ])
        finishRequest(id: request.id, coordinate: latest.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
        guard let request = activeRequest else { return }
        RuntimeLogger.warning("APP", "Location", "Location callback failed", details: [
            "requestID": String(request.id),
            "error": error.localizedDescription
        ])

        let nsError = error as NSError
        let isAuthorizationDenied = nsError.domain == kCLErrorDomain
            && nsError.code == CLError.denied.rawValue

        if request.phase == .oneShot,
           !isAuthorizationDenied,
           authorizationStatus != .denied,
           authorizationStatus != .restricted {
            beginFallback(for: request.id)
        } else {
            finishRequest(id: request.id, coordinate: nil)
        }
        }
    }

    private func freshestCachedLocation(now: Date = Date()) -> CLLocation? {
        let candidates = [location, driver.location].compactMap { $0 }
        for candidate in candidates {
            let valid = Self.isValid(candidate)
            let age = abs(candidate.timestamp.timeIntervalSince(now))
            if !valid || age > cacheMaxAge {
                RealtimeLocationTrace.log("Skipped CLLocationManager cached sample", location: candidate, details: [
                    "Basic validation passed": String(valid),
                    "Cache-age check passed": String(age <= cacheMaxAge),
                    "Maximum cache age (seconds)": String(Int(cacheMaxAge))
                ], level: .warning)
            }
        }
        return candidates
            .filter(Self.isValid)
            .filter { abs($0.timestamp.timeIntervalSince(now)) <= cacheMaxAge }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    private static func isValid(_ location: CLLocation) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy >= 0
    }

    private func scheduleTimeout(for requestID: UInt64, nanoseconds: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.handleTimeout(for: requestID)
        }
    }

    private func handleTimeout(for requestID: UInt64) {
        guard let request = activeRequest, request.id == requestID else { return }
        switch request.phase {
        case .awaitingAuthorization:
            RuntimeLogger.warning("APP", "Location", "Timed out waiting for location authorization", details: ["requestID": String(requestID)])
            finishRequest(id: requestID, coordinate: nil)
        case .oneShot:
            RuntimeLogger.warning("APP", "Location", "One-shot location request timed out; switching to continuous updates", details: ["requestID": String(requestID)])
            beginFallback(for: requestID)
        case .continuousFallback:
            RuntimeLogger.warning("APP", "Location", "Continuous location updates timed out", details: ["requestID": String(requestID)])
            finishRequest(id: requestID, coordinate: nil)
        }
    }

    private func beginOneShot(for requestID: UInt64) {
        guard var request = activeRequest,
              request.id == requestID,
              request.phase == .awaitingAuthorization else { return }
        request.phase = .oneShot
        request.startedAt = Date()
        activeRequest = request
        RuntimeLogger.info("APP", "Real-Time Location", "Starting one-shot CLLocationManager request", details: [
            "requestID": String(requestID),
            "Timeout milliseconds": String(oneShotTimeoutNanoseconds / 1_000_000)
        ])
        scheduleTimeout(for: requestID, nanoseconds: oneShotTimeoutNanoseconds)
        driver.requestLocation()
    }

    private func beginFallback(for requestID: UInt64) {
        guard var request = activeRequest,
              request.id == requestID,
              request.phase == .oneShot else { return }
        request.phase = .continuousFallback
        activeRequest = request
        RuntimeLogger.info("APP", "Real-Time Location", "Starting continuous CLLocationManager fallback", details: [
            "requestID": String(requestID),
            "Timeout milliseconds": String(fallbackTimeoutNanoseconds / 1_000_000)
        ])
        driver.startUpdatingLocation()
        scheduleTimeout(for: requestID, nanoseconds: fallbackTimeoutNanoseconds)
    }

    private func finishRequest(id requestID: UInt64?, coordinate: CLLocationCoordinate2D?) {
        guard let requestID,
              let request = activeRequest,
              request.id == requestID else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        if request.phase == .continuousFallback {
            driver.stopUpdatingLocation()
        }
        activeRequest = nil
        isRequesting = false

        if coordinate != nil {
            RuntimeLogger.info("APP", "Real-Time Location", "CLLocationManager request completed", details: [
                "requestID": String(requestID),
                "Final phase": phaseName(request.phase),
                "Has coordinates": "true"
            ])
        } else {
            RuntimeLogger.warning("APP", "Real-Time Location", "CLLocationManager request ended without coordinates", details: [
                "requestID": String(requestID),
                "Final phase": phaseName(request.phase),
                "Has coordinates": "false"
            ])
        }
        request.continuation.resume(returning: coordinate)
    }

    private func phaseName(_ phase: RequestPhase) -> String {
        switch phase {
        case .awaitingAuthorization: return "awaitingAuthorization"
        case .oneShot: return "oneShot"
        case .continuousFallback: return "continuousFallback"
        }
    }

    private func authorizationName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
