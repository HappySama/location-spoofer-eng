import Combine
import CoreLocation
import Foundation

struct MapSelection: Equatable {
    let coordinate: CLLocationCoordinate2D
    let source: MapSelectionSource
    let explicitName: String?
    let revision: UInt64

    static func == (lhs: MapSelection, rhs: MapSelection) -> Bool {
        lhs.coordinate.isApproximatelyEqual(to: rhs.coordinate)
            && lhs.source == rhs.source
            && lhs.explicitName == rhs.explicitName
            && lhs.revision == rhs.revision
    }
}

enum MapSelectionSource: Equatable {
    case initial
    case userPan
    case mapTap
    case realtime
    case search
    case favorite(UUID)
}

struct RealtimeLocationIntent: Equatable {
    let id: UInt64
    let selectionRevision: UInt64
}

struct MapCameraCommand: Equatable, Identifiable {
    enum Kind: Equatable {
        case focus(coordinate: CLLocationCoordinate2D, distanceMeters: CLLocationDistance)
        case zoom(factor: Double)

        var isZoom: Bool { if case .zoom = self { return true }; return false }

        static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case let (.focus(lhsCoordinate, lhsDistance), .focus(rhsCoordinate, rhsDistance)):
                return lhsCoordinate.isApproximatelyEqual(to: rhsCoordinate)
                    && lhsDistance == rhsDistance
            case let (.zoom(lhsFactor), .zoom(rhsFactor)):
                return lhsFactor == rhsFactor
            default:
                return false
            }
        }
    }

    let id: UInt64
    let kind: Kind
}

struct MapPlaceDescriptor: Equatable {
    var pointOfInterest: String?
    var streetAddress: String?
    var road: String?
    var neighborhood: String?
    var district: String?
    var city: String?
    var province: String?
    var country: String?

    init(
        pointOfInterest: String? = nil,
        streetAddress: String? = nil,
        road: String? = nil,
        neighborhood: String? = nil,
        district: String? = nil,
        city: String? = nil,
        province: String? = nil,
        country: String? = nil
    ) {
        self.pointOfInterest = pointOfInterest?.nonEmpty
        self.streetAddress = streetAddress?.nonEmpty
        self.road = road?.nonEmpty
        self.neighborhood = neighborhood?.nonEmpty
        self.district = district?.nonEmpty
        self.city = city?.nonEmpty
        self.province = province?.nonEmpty
        self.country = country?.nonEmpty
    }

    func displayName(viewportMeters: CLLocationDistance) -> String? {
        switch viewportMeters {
        case ..<1_000:
            return firstAvailable(pointOfInterest, streetAddress, road, neighborhood, district, districtCity, cityProvince, country)
        case ..<5_000:
            return firstAvailable(road, streetAddress, neighborhood, district, districtCity, cityProvince, country)
        case ..<12_000:
            return firstAvailable(neighborhood, district, districtCity, road, city, cityProvince, country)
        case ..<100_000:
            return firstAvailable(districtCity, city, cityProvince, province, country, neighborhoodCity)
        default:
            return firstAvailable(cityProvince, provinceCountry, city, province, country, districtCity)
        }
    }

    private var districtCity: String? { joinedDistinct(district, city) }
    private var neighborhoodCity: String? { joinedDistinct(neighborhood, city) }
    private var cityProvince: String? { joinedDistinct(city, province) }
    private var provinceCountry: String? { joinedDistinct(province, country) }

    private func firstAvailable(_ values: String?...) -> String? {
        values.compactMap { $0?.nonEmpty }.first
    }

    private func joinedDistinct(_ first: String?, _ second: String?) -> String? {
        let values = [first?.nonEmpty, second?.nonEmpty].compactMap { $0 }
        let unique = values.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }
}

@MainActor
final class MapLocationState: ObservableObject {
    @Published private(set) var selection: MapSelection
    @Published private(set) var realtimeCoordinate: CLLocationCoordinate2D?
    @Published private(set) var realtimeLocation: CLLocation?
    @Published private(set) var cameraCommand: MapCameraCommand?
    @Published private(set) var viewportMeters: CLLocationDistance
    @Published private(set) var placeDescriptor: MapPlaceDescriptor?

    private var nextSelectionRevision: UInt64 = 0
    private var nextCameraCommandID: UInt64 = 0
    private var nextRealtimeIntentID: UInt64 = 0
    private var latestRealtimeIntentID: UInt64 = 0

    init(
        initialCoordinate: CLLocationCoordinate2D,
        initialViewportMeters: CLLocationDistance = 1_000,
        initialSource: MapSelectionSource = .initial,
        initialName: String? = nil
    ) {
        viewportMeters = initialViewportMeters
        selection = MapSelection(
            coordinate: initialCoordinate,
            source: initialSource,
            explicitName: initialName?.nonEmpty,
            revision: nextSelectionRevision
        )
    }

    var displayName: String? {
        selection.explicitName?.nonEmpty ?? placeDescriptor?.displayName(viewportMeters: viewportMeters)
    }

    @discardableResult
    func selectUserMapCenter(_ coordinate: CLLocationCoordinate2D) -> UInt64 {
        guard !selection.coordinate.isApproximatelyEqual(to: coordinate) else {
            return selection.revision
        }
        return replaceSelection(coordinate: coordinate, source: .userPan, explicitName: nil, focusDistance: nil)
    }

    @discardableResult
    func selectMapTap(_ coordinate: CLLocationCoordinate2D) -> UInt64 {
        replaceSelection(coordinate: coordinate, source: .mapTap, explicitName: nil, focusDistance: viewportMeters)
    }

    @discardableResult
    func selectSearchResult(
        _ coordinate: CLLocationCoordinate2D,
        name: String
    ) -> UInt64 {
        replaceSelection(coordinate: coordinate, source: .search, explicitName: name, focusDistance: viewportMeters)
    }

    @discardableResult
    func selectFavorite(
        _ coordinate: CLLocationCoordinate2D,
        id: UUID,
        name: String
    ) -> UInt64 {
        replaceSelection(coordinate: coordinate, source: .favorite(id), explicitName: name, focusDistance: viewportMeters)
    }

    func beginRealtimeIntent() -> RealtimeLocationIntent {
        nextRealtimeIntentID &+= 1
        latestRealtimeIntentID = nextRealtimeIntentID
        return RealtimeLocationIntent(id: nextRealtimeIntentID, selectionRevision: selection.revision)
    }

    @discardableResult
    func acceptRealtimeLocation(
        _ coordinate: CLLocationCoordinate2D,
        intent: RealtimeLocationIntent
    ) -> Bool {
        realtimeCoordinate = coordinate
        guard intent.id == latestRealtimeIntentID,
              intent.selectionRevision == selection.revision else {
            return false
        }
        _ = replaceSelection(
            coordinate: coordinate,
            source: .realtime,
            explicitName: nil,
            focusDistance: nil
        )
        return true
    }

    func updateRealtimeLocation(_ location: CLLocation?) {
        guard let location else {
            realtimeLocation = nil
            realtimeCoordinate = nil
            return
        }
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy >= 0 else { return }
        if let current = realtimeLocation, current.timestamp > location.timestamp { return }
        realtimeLocation = location
        realtimeCoordinate = location.coordinate
    }

    func updateRealtimeCoordinate(_ coordinate: CLLocationCoordinate2D?) {
        realtimeCoordinate = coordinate
        if coordinate == nil { realtimeLocation = nil }
    }

    /// Discards a blue-point sample represented in a superseded MapKit
    /// coordinate system. The next native callback repopulates the cache.
    func clearRealtimeLocationForMapCoordinateSystemChange() {
        realtimeLocation = nil
        realtimeCoordinate = nil
    }

    func updateExplicitName(_ name: String, forFavoriteID favoriteID: UUID) {
        guard selection.source == .favorite(favoriteID) else { return }
        selection = MapSelection(
            coordinate: selection.coordinate,
            source: selection.source,
            explicitName: name,
            revision: selection.revision
        )
    }

    func updateViewport(distanceMeters: CLLocationDistance) {
        viewportMeters = max(50, distanceMeters)
    }

    /// Updates only the map representation of the current physical selection.
    /// This preserves revision/source so an in-flight user action is not invalidated.
    func reprojectSelectionForMapCoordinateSystemChange(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate),
              !selection.coordinate.isApproximatelyEqual(to: coordinate) else { return }
        selection = MapSelection(
            coordinate: coordinate,
            source: selection.source,
            explicitName: selection.explicitName,
            revision: selection.revision
        )
        issueCameraCommand(.focus(coordinate: coordinate, distanceMeters: viewportMeters))
    }

    @discardableResult
    func acceptPlaceDescriptor(_ descriptor: MapPlaceDescriptor, selectionRevision: UInt64) -> Bool {
        guard selection.revision == selectionRevision, selection.explicitName == nil else { return false }
        placeDescriptor = descriptor
        return true
    }

    func focusSelection(distanceMeters: CLLocationDistance = 200) {
        issueCameraCommand(.focus(coordinate: selection.coordinate, distanceMeters: distanceMeters))
    }

    func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        issueCameraCommand(.zoom(factor: factor))
    }

    private func replaceSelection(
        coordinate: CLLocationCoordinate2D,
        source: MapSelectionSource,
        explicitName: String?,
        focusDistance: CLLocationDistance?
    ) -> UInt64 {
        nextSelectionRevision &+= 1
        placeDescriptor = nil
        selection = MapSelection(
            coordinate: coordinate,
            source: source,
            explicitName: explicitName?.nonEmpty,
            revision: nextSelectionRevision
        )
        if let focusDistance {
            issueCameraCommand(.focus(coordinate: coordinate, distanceMeters: focusDistance))
        }
        return nextSelectionRevision
    }

    private func issueCameraCommand(_ kind: MapCameraCommand.Kind) {
        nextCameraCommandID &+= 1
        cameraCommand = MapCameraCommand(id: nextCameraCommandID, kind: kind)
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension CLLocationCoordinate2D {
    func isApproximatelyEqual(to other: CLLocationCoordinate2D, tolerance: CLLocationDegrees = 0.000_001) -> Bool {
        abs(latitude - other.latitude) < tolerance && abs(longitude - other.longitude) < tolerance
    }
}

// MARK: - 持久化存储

struct LastCoordinate: Codable, Equatable {
    let coordinatePair: CoordinatePair
    let zoomMeters: CLLocationDistance

    func coordinate(for mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem) -> CLLocationCoordinate2D {
        coordinatePair.coordinate(for: mapCoordinateSystem)
    }
}

enum LastCoordinateStore {
    private struct StoredPosition: Codable {
        let coordinatePair: CoordinatePair
        let zoomMeters: CLLocationDistance
    }

    private static let positionKey = "lastMapPositionV1"
    private static let legacyLatKey = "lastMapLat"
    private static let legacyLonKey = "lastMapLon"

    static func save(
        mapCoordinate: CLLocationCoordinate2D,
        mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem,
        zoomMeters: CLLocationDistance,
        defaults: UserDefaults = AppGroup.defaults
    ) {
        save(
            coordinatePair: .init(mapCoordinate: mapCoordinate, mapCoordinateSystem: mapCoordinateSystem),
            zoomMeters: zoomMeters,
            defaults: defaults
        )
    }

    static func save(
        coordinatePair: CoordinatePair,
        zoomMeters: CLLocationDistance,
        defaults: UserDefaults = AppGroup.defaults
    ) {
        do {
            let value = StoredPosition(coordinatePair: coordinatePair, zoomMeters: max(50, zoomMeters))
            defaults.set(try JSONEncoder().encode(value), forKey: positionKey)
            ViewportStore.save(value.zoomMeters, defaults: defaults)
        } catch {
            RuntimeLogger.error("APP", "Map", "Failed to save the current pin", error: error)
        }
    }

    static func load(defaults: UserDefaults = AppGroup.defaults) -> LastCoordinate? {
        if let data = defaults.data(forKey: positionKey),
           let value = try? JSONDecoder().decode(StoredPosition.self, from: data) {
            return LastCoordinate(coordinatePair: value.coordinatePair, zoomMeters: value.zoomMeters)
        }

        let legacyLatitude = defaults.double(forKey: legacyLatKey)
        let legacyLongitude = defaults.double(forKey: legacyLonKey)
        let legacy = CLLocationCoordinate2D(latitude: legacyLatitude, longitude: legacyLongitude)
        guard CLLocationCoordinate2DIsValid(legacy), legacyLatitude != 0 || legacyLongitude != 0 else {
            return nil
        }
        return LastCoordinate(
            coordinatePair: CoordinateConverter.legacyCoordinatePair(lat: legacyLatitude, lon: legacyLongitude),
            zoomMeters: ViewportStore.load(defaults: defaults) ?? 1_000
        )
    }

    static func updateZoom(_ meters: CLLocationDistance, defaults: UserDefaults = AppGroup.defaults) {
        guard let current = load(defaults: defaults) else { return }
        save(coordinatePair: current.coordinatePair, zoomMeters: meters, defaults: defaults)
    }

    static func migrateLegacyCoordinate(
        defaults: UserDefaults = AppGroup.defaults,
        legacyDefaults: UserDefaults = .standard
    ) throws {
        guard defaults.data(forKey: positionKey) == nil else { return }
        let legacyLatitude = legacyDefaults.double(forKey: legacyLatKey)
        let legacyLongitude = legacyDefaults.double(forKey: legacyLonKey)
        let legacy = CLLocationCoordinate2D(latitude: legacyLatitude, longitude: legacyLongitude)
        guard CLLocationCoordinate2DIsValid(legacy), legacyLatitude != 0 || legacyLongitude != 0 else { return }
        let value = StoredPosition(
            coordinatePair: CoordinateConverter.legacyCoordinatePair(lat: legacyLatitude, lon: legacyLongitude),
            zoomMeters: ViewportStore.load(defaults: legacyDefaults) ?? 1_000
        )
        defaults.set(try JSONEncoder().encode(value), forKey: positionKey)
    }
}

enum ViewportStore {
    private static let key = "mapViewportMeters"

    static func save(_ meters: CLLocationDistance, defaults: UserDefaults = AppGroup.defaults) {
        let value = max(50, meters)
        defaults.set(value, forKey: key)
        RuntimeLogger.info("APP", "Zoom", "Saved zoom level", details: ["zoom": String(value)])
    }

    static func load(defaults: UserDefaults = AppGroup.defaults) -> CLLocationDistance? {
        let value = defaults.double(forKey: key)
        return value > 0 ? value : nil
    }

    static func loadOrDefault(defaults: UserDefaults = AppGroup.defaults) -> CLLocationDistance {
        if let value = load(defaults: defaults) { return value }
        let fallback: CLLocationDistance = 1_000
        save(fallback, defaults: defaults)
        return fallback
    }
}

enum CoordinateStorageMigration {
    private static let versionKey = "coordinateStorageMigrationVersion"
    static let currentVersion = 1

    static func migrateIfNeeded(
        favorites: FavoriteLocationStore,
        defaults: UserDefaults = AppGroup.defaults,
        legacyDefaults: UserDefaults = .standard
    ) throws {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        // Pre-migration map pin and viewport values lived in UserDefaults.standard;
        // favorites already lived in App Group defaults.
        try LastCoordinateStore.migrateLegacyCoordinate(
            defaults: defaults,
            legacyDefaults: legacyDefaults
        )
        try favorites.migrateLegacyCoordinates()
        defaults.set(currentVersion, forKey: versionKey)
        RuntimeLogger.info("APP", "Coordinate Conversion", "Legacy coordinate data migration completed")
    }
}
