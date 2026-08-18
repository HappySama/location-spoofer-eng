import CoreLocation
import Foundation

struct FavoriteLocation: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var coordinatePair: CoordinatePair
    var accuracy: Int
    var createdAt: Date
    private var wasDecodedFromLegacyCoordinates = false

    /// WGS-84 compatibility accessor. WLOC consumers must use this value.
    var latitude: Double { coordinatePair.wgs84.latitude }
    var longitude: Double { coordinatePair.wgs84.longitude }
    var isLegacyCoordinateRecord: Bool { wasDecodedFromLegacyCoordinates }

    init(
        id: UUID = UUID(),
        name: String,
        coordinatePair: CoordinatePair,
        accuracy: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.coordinatePair = coordinatePair
        self.accuracy = accuracy
        self.createdAt = createdAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        accuracy: Int,
        createdAt: Date = Date(),
        mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem = .gcj02
    ) {
        self.init(
            id: id,
            name: name,
            coordinatePair: CoordinateConverter.coordinatePair(lat: latitude, lon: longitude, mapCoordinateSystem: mapCoordinateSystem),
            accuracy: accuracy,
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, coordinatePair, accuracy, createdAt, latitude, longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        accuracy = try container.decode(Int.self, forKey: .accuracy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let pair = try container.decodeIfPresent(CoordinatePair.self, forKey: .coordinatePair) {
            coordinatePair = pair
        } else {
            let latitude = try container.decode(Double.self, forKey: .latitude)
            let longitude = try container.decode(Double.self, forKey: .longitude)
            coordinatePair = CoordinateConverter.legacyCoordinatePair(lat: latitude, lon: longitude)
            wasDecodedFromLegacyCoordinates = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(coordinatePair, forKey: .coordinatePair)
        try container.encode(accuracy, forKey: .accuracy)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

struct MapConfiguration: Equatable {
    let showsUserLocation: Bool
    let allowsCurrentLocationRequest: Bool

    static let `default` = MapConfiguration(showsUserLocation: false, allowsCurrentLocationRequest: false)
}

final class FavoriteLocationStore: ObservableObject {
    private enum Keys {
        static let favorites = "favorite_locations"
        static let selectedID = "favorite_locations_selected_id"
    }

    @Published private(set) var favorites: [FavoriteLocation]
    @Published private(set) var selectedFavoriteID: UUID?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.favorites),
           let decoded = try? JSONDecoder().decode([FavoriteLocation].self, from: data) {
            self.favorites = decoded
        } else {
            self.favorites = []
        }
        self.selectedFavoriteID = defaults.string(forKey: Keys.selectedID).flatMap(UUID.init(uuidString:))
    }

    var selectedFavorite: FavoriteLocation? {
        guard let selectedFavoriteID else { return nil }
        return favorites.first(where: { $0.id == selectedFavoriteID })
    }

    @discardableResult
    func save(
        name: String,
        mapCoordinate: CLLocationCoordinate2D,
        mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem,
        accuracy: Int
    ) -> FavoriteLocation {
        save(
            FavoriteLocation(
                name: name,
                coordinatePair: .init(mapCoordinate: mapCoordinate, mapCoordinateSystem: mapCoordinateSystem),
                accuracy: accuracy
            )
        )
    }

    /// Saves a coordinate pair whose source representation was already typed
    /// before an asynchronous map-coordinate-system refresh.
    @discardableResult
    func save(name: String, coordinatePair: CoordinatePair, accuracy: Int) -> FavoriteLocation {
        save(FavoriteLocation(name: name, coordinatePair: coordinatePair, accuracy: accuracy))
    }

    @discardableResult
    private func save(_ favorite: FavoriteLocation) -> FavoriteLocation {
        favorites.removeAll {
            abs($0.coordinatePair.wgs84.latitude - favorite.coordinatePair.wgs84.latitude) < 0.000001
                && abs($0.coordinatePair.wgs84.longitude - favorite.coordinatePair.wgs84.longitude) < 0.000001
        }
        favorites.insert(favorite, at: 0)
        select(favorite.id)
        persistIgnoringFailure()
        return favorite
    }

    /// Compatibility entry point for callers that already own raw map values.
    @discardableResult
    func save(name: String, latitude: Double, longitude: Double, accuracy: Int, mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem = .gcj02) -> FavoriteLocation {
        save(
            name: name,
            mapCoordinate: .init(latitude: latitude, longitude: longitude),
            mapCoordinateSystem: mapCoordinateSystem,
            accuracy: accuracy
        )
    }

    func select(_ id: UUID?) {
        selectedFavoriteID = id
        defaults.set(id?.uuidString, forKey: Keys.selectedID)
    }

    @discardableResult
    func selectMatching(coordinatePair: CoordinatePair) -> FavoriteLocation? {
        let matchingFavorite = favorites.first {
            $0.coordinatePair.matchesWGS84(
                latitude: coordinatePair.wgs84.latitude,
                longitude: coordinatePair.wgs84.longitude
            )
        }
        select(matchingFavorite?.id)
        return matchingFavorite
    }

    func rename(_ id: UUID, to name: String) {
        guard let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[idx].name = name
        persistIgnoringFailure()
    }

    func delete(_ favorite: FavoriteLocation) {
        favorites.removeAll { $0.id == favorite.id }
        if selectedFavoriteID == favorite.id {
            select(favorites.first?.id)
        }
        persistIgnoringFailure()
    }

    func migrateLegacyCoordinates() throws {
        guard favorites.contains(where: \.isLegacyCoordinateRecord) else { return }
        try persist()
    }

    private func persistIgnoringFailure() {
        do {
            try persist()
        } catch {
            RuntimeLogger.error("APP", "Favorites", "Failed to save favorites", error: error)
        }
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(favorites), forKey: Keys.favorites)
    }
}
