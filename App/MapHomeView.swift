import SwiftUI
import MapKit
import UIKit
import CoreLocation

private struct SearchLocationResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}

private enum HomeSheet: String, Identifiable {
    case settings, logs
    var id: String { rawValue }
}

private enum SpoofState {
    case idle, verifying, active
}

private struct RealtimeLocationRequestContext {
    let intent: RealtimeLocationIntent
    let source: String
    let showFailureAlert: Bool
}

private enum RealtimeCoordinateSource: Equatable {
    case mapKitBluePoint
    case coreLocation

    @MainActor
    var coordinateSystem: CoordinateConverter.MapCoordinateSystem {
        switch self {
        case .mapKitBluePoint: return CoordinateConverter.currentMapCoordinateSystem
        case .coreLocation: return .wgs84
        }
    }

    var diagnosticName: String {
        switch self {
        case .mapKitBluePoint: return "MapKit blue location dot"
        case .coreLocation: return "CLLocationManager"
        }
    }
}

struct MapHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var setup: SetupCoordinator
    @StateObject private var favorites: FavoriteLocationStore
    @StateObject private var actions = LocationActionCoordinator()
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @StateObject private var realtime = RealtimeLocationManager.shared
    @StateObject private var mapState: MapLocationState
    @ObservedObject private var net = NetworkMonitor.shared

    @State private var searchText = ""
    @State private var searchResults: [SearchLocationResult] = []
    @State private var isSearching = false
    @State private var searchRequestID: UInt64 = 0
    @State private var searchError = ""
    @State private var mapRuntimeDidStart = false
    @State private var activeSheet: HomeSheet?
    @State private var showEnableTip = false
    @State private var showDisableTip = false
    @State private var activeTip: TipKind?
    @State private var manualHint = ""
    private let tipPreferences = VirtualLocationTipPreferences()
    private let communityPromptPreferences = ThirdPartyCommunityPromptPreferences()
    @State private var pendingCommunityContributionClient: ThirdPartyProxyClient?
    @State private var communityContributionClient: ThirdPartyProxyClient?
    @State private var showCommunityTemplateCopied = false
    @State private var githubDestination: SafariDestination?
    @State private var editingFavorite: FavoriteLocation?
    @State private var editName = ""
    @State private var reverseGeocodeTask: Task<Void, Never>?
    @State private var geocodeDebounceTask: Task<Void, Never>?
    @State private var showLocationAlert = false
    @State private var realtimeRequestTask: Task<Void, Never>?
    @State private var realtimeRequestContext: RealtimeLocationRequestContext?
    @State private var wifiChangeObserverToken: UUID?
    @State private var wifiVerificationTask: Task<Void, Never>?
    @State private var wifiVerificationID: UUID?
    @State private var copiedCoordinateSystem: CoordinateConverter.MapCoordinateSystem?
    @State private var spoofState: SpoofState = .idle
    @State private var locationOperationTask: Task<Void, Never>?
    @State private var locationOperationID: UInt64 = 0
    @State private var mapCoordinateSystemRefreshTask: Task<Void, Never>?
    @State private var mapCoordinateSystemRefreshID: UInt64 = 0
    @State private var bluePointRefreshPending = false
    @State private var realtimeButtonTask: Task<Void, Never>?
    @State private var favoriteSaveTask: Task<Void, Never>?
    // 激活时的坐标（本地存，绕过 C 桥接层精度丢失）
    @State private var activeSpoofLat: Double?
    @State private var activeSpoofLon: Double?
    @State private var lastSpoofDiagnosisSystem: CoordinateConverter.MapCoordinateSystem?
    @State private var hasLoggedSpoofDiagnosis = false

    init(setup: SetupCoordinator) {
        self.setup = setup
        let favoriteStore = FavoriteLocationStore()
        _favorites = StateObject(wrappedValue: favoriteStore)
        let savedCoord = LastCoordinateStore.load()
        let initialZoom = savedCoord?.zoomMeters ?? ViewportStore.loadOrDefault()
        let selectedFavorite = favoriteStore.selectedFavorite
        let initialCoord: CLLocationCoordinate2D
        let initialSource: MapSelectionSource
        let initialName: String?
        if let saved = savedCoord {
            initialCoord = saved.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            if let selectedFavorite,
               selectedFavorite.coordinatePair.matchesWGS84(
                   latitude: saved.coordinatePair.wgs84.latitude,
                   longitude: saved.coordinatePair.wgs84.longitude
               ) {
                initialSource = .favorite(selectedFavorite.id)
                initialName = selectedFavorite.name
            } else {
                initialSource = .initial
                initialName = nil
            }
        } else if let selectedFavorite {
            initialCoord = selectedFavorite.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            initialSource = .favorite(selectedFavorite.id)
            initialName = selectedFavorite.name
        } else {
            // The fallback location is defined as WGS-84 and rendered in the
            // coordinate system resolved by the startup gate.
            initialCoord = CoordinateConverter.coordinatePair(
                lat: 22.544577,
                lon: 113.94114,
                mapCoordinateSystem: .wgs84
            ).coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            initialSource = .initial
            initialName = nil
        }
        RuntimeLogger.info("APP", "Map", "Initialized", details: [
            "zoom": String(initialZoom),
            "Has cached location": String(savedCoord != nil),
            "Initial source": String(describing: initialSource),
            "Map coordinate system": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        _mapState = StateObject(wrappedValue: MapLocationState(
            initialCoordinate: initialCoord,
            initialViewportMeters: initialZoom,
            initialSource: initialSource,
            initialName: initialName
        ))

        if ProxyRuntimeModeStore.shared.mode == .localWiFi,
           let settings = WlocSettingsStore.load(), settings.enabled {
            _spoofState = State(initialValue: .active)
            _activeSpoofLat = State(initialValue: settings.latitude)
            _activeSpoofLon = State(initialValue: settings.longitude)
        }
    }

    var body: some View {
        ZStack {
            MapViewRepresentable(
                selection: mapState.selection,
                initialViewportMeters: mapState.viewportMeters,
                cameraCommand: mapState.cameraCommand,
                onRealtimeLocationChanged: { location in
                    handleNativeRealtimeLocation(location)
                },
                onUserCenterChanged: { coordinate, distance in
                    mapState.updateViewport(distanceMeters: distance)
                    let previousRevision = mapState.selection.revision
                    let revision = mapState.selectUserMapCenter(coordinate)
                    guard revision != previousRevision else { return }
                    let pair = CoordinatePair(
                        mapCoordinate: coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    LastCoordinateStore.save(
                        coordinatePair: pair,
                        zoomMeters: mapState.viewportMeters
                    )
                    favorites.select(nil)
                    scheduleGeocode(pair: pair, revision: revision)
                },
                onViewportChanged: { distance in
                    mapState.updateViewport(distanceMeters: distance)
                },
                onMapTap: { coordinate in
                    favorites.select(nil)
                    let revision = mapState.selectMapTap(coordinate)
                    let pair = CoordinatePair(
                        mapCoordinate: coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    LastCoordinateStore.save(
                        coordinatePair: pair,
                        zoomMeters: mapState.viewportMeters
                    )
                    scheduleGeocode(pair: pair, revision: revision)
                },
                onUserZoomChanged: { distance in
                    ViewportStore.save(distance)
                    LastCoordinateStore.updateZoom(distance)
                },
                onZoomIn: { mapState.zoom(by: 0.5) },
                onZoomOut: { mapState.zoom(by: 2) }
            )
            .ignoresSafeArea(.container)

            VStack(spacing: 10) {
                topControls
                if !searchResults.isEmpty || !searchError.isEmpty { searchResultList }
                Spacer()
                // 右下角按钮
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Button {
                            if let url = URL(string: "maps://app") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        }
                        Button {
                            requestRealtimeLocation()
                        } label: {
                            if realtime.isRequesting {
                                ProgressView()
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            } else {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            }
                        }
                        .disabled(realtimeButtonTask != nil || realtimeRequestTask != nil || realtime.isRequesting)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .navigationBarHidden(true)
        .sheet(item: $activeSheet) { sheet in
            NavigationView {
                switch sheet {
                case .settings: SettingsView(setup: setup, actions: actions)
                case .logs: RuntimeLogsView(setup: setup, actions: actions, testFavorite: testFavorite)
                }
            }
        }
        .sheet(item: $activeTip) { kind in
            TipSheetView(kind: kind, runtimeMode: runtimeMode.mode)
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
        .alert("Share a Working Configuration?", isPresented: Binding(
            get: { communityContributionClient != nil },
            set: { if !$0 { communityContributionClient = nil } }
        )) {
            Button("Submit") {
                guard let client = communityContributionClient else { return }
                UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                    for: client,
                    systemVersion: UIDevice.current.systemVersion
                )
                openCommunityContributionPage()
            }
            Button("Copy Template") {
                guard let client = communityContributionClient else { return }
                UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                    for: client,
                    systemVersion: UIDevice.current.systemVersion
                )
                showCommunityTemplateCopied = true
            }
            if communityPromptPreferences.canSuppress() {
                Button("Don't Ask Again", role: .cancel) {
                    communityPromptPreferences.suppress()
                }
            } else {
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(
                "You're using \(communityContributionClient?.name ?? "a third-party client"). Tapping Submit copies a contribution template and opens the community page in the app. Accepted configurations are added to the README, and you may choose whether to be credited."
            )
        }
        .alert("Contribution Template Copied", isPresented: $showCommunityTemplateCopied) {
            Button("Got It", role: .cancel) {}
        } message: {
            Text("If the template is not filled automatically after GitHub sign-in or a browser redirect, paste it manually.")
        }
        .alert("Unable to Open Page", isPresented: Binding(
            get: { !manualHint.isEmpty },
            set: { if !$0 { manualHint = "" } }
        )) {
            Button("Got It", role: .cancel) {}
        } message: { Text(manualHint) }
        .onAppear {
            startMapRuntimeOnce()
            if runtimeMode.mode == .localWiFi {
                registerWiFiChangeObserver()
            } else {
                refreshThirdPartyState()
            }
        }
        .onDisappear {
            if let token = wifiChangeObserverToken {
                net.removeWiFiChangeObserver(token)
                wifiChangeObserverToken = nil
            }
            wifiVerificationTask?.cancel()
            wifiVerificationTask = nil
            wifiVerificationID = nil
            mapCoordinateSystemRefreshTask?.cancel()
            mapCoordinateSystemRefreshTask = nil
            bluePointRefreshPending = false
            realtimeButtonTask?.cancel()
            realtimeButtonTask = nil
            favoriteSaveTask?.cancel()
            favoriteSaveTask = nil
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { @MainActor in
                await awaitCoordinatedMapCoordinateSystemRefresh(reason: "App returned to foreground")
            }
        }
        .onChange(of: proxy.isRunning) { running in
            if runtimeMode.mode == .localWiFi, !running && spoofState == .active {
                spoofState = .idle
                actions.clear()
            }
        }
        .onChange(of: showEnableTip) { isPresented in
            guard !isPresented, let client = pendingCommunityContributionClient else { return }
            pendingCommunityContributionClient = nil
            DispatchQueue.main.async {
                communityContributionClient = client
            }
        }
        .onChange(of: runtimeMode.mode) { mode in
            locationOperationTask?.cancel()
            locationOperationTask = nil
            locationOperationID &+= 1
            if let token = wifiChangeObserverToken {
                net.removeWiFiChangeObserver(token)
                wifiChangeObserverToken = nil
            }
            wifiVerificationTask?.cancel()
            wifiVerificationTask = nil
            activeSpoofLat = nil
            activeSpoofLon = nil
            if mode == .localWiFi {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
                registerWiFiChangeObserver()
            } else {
                spoofState = .idle
                refreshThirdPartyState()
            }
        }
        .sheet(isPresented: $showEnableTip) { enableTipSheet }
        .sheet(isPresented: $showDisableTip) { disableTipSheet }
        .alert("Location Unavailable", isPresented: $showLocationAlert) {
            Button("Open Settings") {
                openSettings(.locationServices)
            }
            Button("Got It", role: .cancel) {}
        } message: {
            Text("The current location could not be determined. Make sure Location Services is enabled.")
        }
        .alert("Rename Favorite", isPresented: Binding(
            get: { editingFavorite != nil },
            set: { if !$0 { editingFavorite = nil } }
        )) {
            TextField("Name", text: $editName)
            Button("Save") {
                if let f = editingFavorite {
                    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = name.isEmpty ? f.name : name
                    favorites.rename(f.id, to: finalName)
                    mapState.updateExplicitName(finalName, forFavoriteID: f.id)
                }
                editingFavorite = nil
            }
            Button("Cancel", role: .cancel) { editingFavorite = nil }
        } message: { Text("Enter a new name for this favorite.") }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for a place or coordinates", text: $searchText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit(doSearch)
                if isSearching { ProgressView().controlSize(.small) }
                else if !searchText.isEmpty {
                    Button {
                        searchRequestID &+= 1
                        isSearching = false
                        searchText = ""
                        searchResults = []
                        searchError = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Button(action: doSearch) { Image(systemName: "arrow.right.circle.fill").font(.title3) }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
            Menu {
                Button { activeSheet = .logs } label: { Label("Logs", systemImage: "list.bullet.rectangle") }
                Button { activeSheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
                    .contentShape(Circle())
            }.accessibilityLabel("More")
        }
    }

    // 搜索列表：动态高度，不写死
    private var searchResultList: some View {
        VStack(spacing: 0) {
            if !searchError.isEmpty {
                Text(searchError).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ForEach(searchResults) { r in
                HStack(spacing: 8) {
                    Button { selectSearchResult(r) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button(role: .destructive) { deleteSearchResult(r) } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                if r.id != searchResults.last?.id { Divider().padding(.leading, 46) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 底部：当前选点 + 收藏 + 主控按钮
    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 当前选点
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mapState.displayName ?? "Selected Location").font(.subheadline.weight(.semibold)).lineLimit(1)
                    coordinateRow(label: "GCJ-02 (China)", system: .gcj02)
                    coordinateRow(label: "WGS-84 (Global)", system: .wgs84)
                }
                Spacer()
                // 帮助说明按钮
                Button {
                    if spoofState == .active {
                        activeTip = .activation
                    } else {
                        activeTip = .deactivation
                    }
                } label: {
                    Text(spoofState == .active ? "Not working?" : "Still spoofed?")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                // 收藏按钮
                Button {
                    if favorites.selectedFavoriteID != nil {
                        favorites.select(nil)
                        return
                    }
                    saveCurrentSelectionAsFavorite()
                } label: {
                    Image(systemName: favorites.selectedFavoriteID != nil ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background((favorites.selectedFavoriteID != nil ? Color.yellow : Color.gray).opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(favorites.selectedFavoriteID != nil ? .orange : .gray)
                .disabled(favoriteSaveTask != nil)
                .accessibilityLabel(favorites.selectedFavoriteID != nil ? "Favorited; tap to remove from favorites" : "Save the selected location as a favorite")
            }
            // 收藏
            if favorites.favorites.isEmpty {
                Text("Search or tap the map to select a location, then save it as a favorite.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(favorites.favorites) { f in favoriteChip(f) } }.padding(.vertical, 2)
                }
            }
            // 主控按钮（带动画）
            HStack(spacing: 10) {
                Button(action: handleMainButtonTap) {
                    HStack(spacing: 6) {
                        if spoofState == .verifying {
                            ProgressView().tint(.white)
                        }
                        Text(spoofState == .active && needsSwitchButton ? "Stop" : buttonTitle)
                            .font(.headline).lineLimit(1)
                    }
                    .frame(maxWidth: needsSwitchButton ? nil : .infinity)
                    .frame(minWidth: needsSwitchButton ? 56 : nil)
                    .padding(.vertical, 14)
                    .padding(.horizontal, needsSwitchButton ? 12 : 14)
                }
                .background(buttonColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
                .disabled(spoofState == .verifying)

                if needsSwitchButton {
                    Button {
                        beginLocationOperation()
                    } label: {
                        Label("Switch to This Location", systemImage: "arrow.triangle.swap")
                            .font(.body.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12).padding(.horizontal, 16)
                    }
                    .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: needsSwitchButton)
            .padding(.top, 4)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }


    private var needsSwitchButton: Bool {
        guard spoofState == .active,
              let sLat = activeSpoofLat,
              let sLon = activeSpoofLon else { return false }
        return !currentSelectionFavorite.coordinatePair.matchesWGS84(
            latitude: sLat,
            longitude: sLon
        )
    }

    private var buttonTitle: String {
        if runtimeMode.mode == .thirdParty {
            switch spoofState {
            case .idle: return "Send to Third-Party Proxy"
            case .verifying: return "Testing and Sending…"
            case .active: return "Stop Third-Party Location"
            }
        }
        switch spoofState {
        case .idle: return "Start Virtual Location"
        case .verifying: return "Checking Environment…"
        case .active: return "Stop Virtual Location"
        }
    }

    private var buttonColor: Color {
        switch spoofState {
        case .idle: return .blue
        case .verifying: return .gray
        case .active: return .green
        }
    }

    private func handleMainButtonTap() {
        switch spoofState {
        case .idle:
            beginLocationOperation()
        case .active:
            stopSpoofing()
        case .verifying:
            break
        }
    }

    private func beginLocationOperation() {
        guard spoofState != .verifying, locationOperationTask == nil else { return }
        let wasActive = spoofState == .active
        locationOperationID &+= 1
        let operationID = locationOperationID
        let selectionRevision = mapState.selection.revision
        let target = currentSelectionFavorite
        spoofState = .verifying

        locationOperationTask = Task { @MainActor in
            if runtimeMode.mode == .thirdParty {
                do {
                    let response = try await thirdPartyProxy.save(target)
                    guard !Task.isCancelled,
                          operationID == locationOperationID,
                          runtimeMode.mode == .thirdParty else {
                        return
                    }
                    // The remote write has already succeeded. If the user moved
                    // the map meanwhile, keep this target active and let
                    // needsSwitchButton offer syncing the newer selection.
                    spoofState = .active
                    activeSpoofLat = response.latitude
                    activeSpoofLon = response.longitude
                    RuntimeLogger.info("APP", "Location", "Coordinates synchronized to third-party proxy", details: [
                        "Client": thirdPartyClient.selectedClient.name,
                        "Coordinate system": "WGS-84",
                        "Client mode": "Third-Party Proxy Mode",
                        "Selection changed during operation": String(selectionRevision != mapState.selection.revision)
                    ])
                    presentSuccessfulOperationTip(.activation)
                    queueCommunityContributionPrompt(for: thirdPartyClient.selectedClient)
                } catch {
                    guard operationID == locationOperationID else { return }
                    // A failed replacement does not clear the coordinate that
                    // was already persisted inside the third-party client.
                    spoofState = wasActive ? .active : .idle
                    RuntimeLogger.error(
                        "APP",
                        "ThirdPartyProxy",
                        "Failed to synchronize coordinates to the third-party client",
                        error: error,
                        details: [
                            "Client": thirdPartyClient.selectedClient.name,
                            "Request": "WLOC save",
                            "Restored state": wasActive ? "Retained previous third-party coordinates" : "Remained disabled",
                            "Suggested fix": ThirdPartyProxyError.recoverySuggestion(for: error)
                        ]
                    )
                    setup.requestThirdPartySetup(message: error.localizedDescription)
                }
                if operationID == locationOperationID {
                    locationOperationTask = nil
                }
                return
            }

            let result = await setup.runVerificationTest()
            guard !Task.isCancelled,
                  operationID == locationOperationID,
                  selectionRevision == mapState.selection.revision else {
                if operationID == locationOperationID {
                    spoofState = actions.virtualLocationEnabled ? .active : .idle
                    locationOperationTask = nil
                }
                return
            }

            if result.isSuccess {
                let applied = actions.applyVerified(target)
                spoofState = applied ? .active : .idle
                if applied {
                    activeSpoofLat = target.latitude
                    activeSpoofLon = target.longitude
                    lastSpoofDiagnosisSystem = nil
                    hasLoggedSpoofDiagnosis = false
                }
                RuntimeLogger.info("APP", "Location", "Verification result", details: [
                    "success": "true",
                    "applied": String(applied),
                    "spoofState": String(describing: spoofState)
                ])
                if applied {
                    presentSuccessfulOperationTip(.activation)
                }
            } else {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
                RuntimeLogger.warning("APP", "Location", "Verification failed", details: [
                    "result": result.id,
                    "spoofState": String(describing: spoofState)
                ])
                if result != .verificationInProgress,
                   result != .verificationSuperseded {
                    RuntimeLogger.warning("APP", "Location", "Pre-activation check failed; opening the relevant setup guide", details: [
                        "Result": result.id
                    ])
                    activeTip = nil
                    setup.applyVerificationResult(result)
                }
            }
            locationOperationTask = nil
        }
    }

    private func stopSpoofing() {
        locationOperationTask?.cancel()
        locationOperationTask = nil
        locationOperationID &+= 1
        if runtimeMode.mode == .thirdParty {
            spoofState = .verifying
            locationOperationTask = Task { @MainActor in
                do {
                    try await thirdPartyProxy.clear()
                    spoofState = .idle
                    activeSpoofLat = nil
                    activeSpoofLon = nil
                    presentSuccessfulOperationTip(.deactivation)
                } catch {
                    spoofState = .active
                    RuntimeLogger.error(
                        "APP",
                        "ThirdPartyProxy",
                        "Failed to clear coordinates from the third-party client",
                        error: error,
                        details: [
                            "Client": thirdPartyClient.selectedClient.name,
                            "Request": "WLOC clear",
                            "Restored state": "Remained enabled",
                            "Suggested fix": ThirdPartyProxyError.recoverySuggestion(for: error)
                        ]
                    )
                    setup.requestThirdPartySetup(message: error.localizedDescription)
                }
                locationOperationTask = nil
            }
            return
        }

        actions.clear()
        spoofState = .idle
        activeSpoofLat = nil
        activeSpoofLon = nil
        lastSpoofDiagnosisSystem = nil
        hasLoggedSpoofDiagnosis = false
        presentSuccessfulOperationTip(.deactivation)
    }

    private func presentSuccessfulOperationTip(_ kind: VirtualLocationTipKind) {
        let count = tipPreferences.recordSuccessfulOperation(kind)
        let operationName = kind == .activation ? "activation" : "deactivation"
        RuntimeLogger.info("APP", "Tips", "Updated virtual-location \(operationName) count", details: [
            "Count": String(count),
            "Runtime mode": runtimeMode.mode.displayName,
            "Can show Don't Remind Me Again": String(tipPreferences.canSuppress(kind))
        ])
        guard tipPreferences.shouldPresentAutomaticTip(kind) else { return }
        switch kind {
        case .activation:
            showEnableTip = true
        case .deactivation:
            showDisableTip = true
        }
    }

    private func queueCommunityContributionPrompt(for client: ThirdPartyProxyClient) {
        guard remoteConfiguration.requestsCommunityPrompt(for: client),
              communityPromptPreferences.shouldPresent() else {
            return
        }
        communityPromptPreferences.recordPresentation()
        if showEnableTip {
            pendingCommunityContributionClient = client
        } else {
            communityContributionClient = client
        }
    }

    private func openCommunityContributionPage() {
        githubDestination = SafariDestination(url: GitHubSubmission.communityContributionURL)
    }


    private func favoriteChip(_ f: FavoriteLocation) -> some View {
        HStack(spacing: 0) {
            Button { select(f) } label: {
                Label(f.name, systemImage: favorites.selectedFavoriteID == f.id ? "checkmark.circle.fill" : "mappin")
                    .lineLimit(1).padding(.leading, 10).padding(.vertical, 8).padding(.trailing, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().frame(height: 22)
            Button {
                editingFavorite = f
                editName = f.name
            } label: {
                Image(systemName: "pencil").font(.caption2).frame(width: 32, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.55))
            Divider().frame(height: 22)
            Button(role: .destructive) { favorites.delete(f) } label: {
                Image(systemName: "trash").font(.caption.weight(.semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .background((favorites.selectedFavoriteID == f.id ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12)), in: Capsule())
        .overlay(Capsule().stroke(favorites.selectedFavoriteID == f.id ? Color.red.opacity(0.7) : Color.clear))
    }

    @MainActor
    private func openSettings(_ destination: SystemSettingsDestination) {
        SystemSettingsNavigator.open(destination) { fallbackHint in
            if let fallbackHint { manualHint = fallbackHint }
        }
    }


    private var currentSelectionFavorite: FavoriteLocation {
        FavoriteLocation(
            name: mapState.displayName ?? String(
                format: "%.4f, %.4f",
                mapState.selection.coordinate.latitude,
                mapState.selection.coordinate.longitude
            ),
            coordinatePair: .init(
                mapCoordinate: mapState.selection.coordinate,
                mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
            ),
            accuracy: 25
        )
    }

    private var currentSelectionPair: CoordinatePair {
        if let stored = LastCoordinateStore.load(),
           stored.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            .isApproximatelyEqual(to: mapState.selection.coordinate) {
            return stored.coordinatePair
        }
        return CoordinatePair(
            mapCoordinate: mapState.selection.coordinate,
            mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
        )
    }

    private func coordinateRow(
        label: String,
        system: CoordinateConverter.MapCoordinateSystem
    ) -> some View {
        let coordinate = currentSelectionPair.coordinate(for: system)
        let text = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(copiedCoordinateSystem == system ? .green : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .layoutPriority(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = text
            copiedCoordinateSystem = system
            RuntimeLogger.info("APP", "Map", "Coordinates copied", details: [
                "Coordinate system": system.diagnosticName
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedCoordinateSystem == system { copiedCoordinateSystem = nil }
            }
        }
        .overlay(alignment: .topTrailing) {
            if copiedCoordinateSystem == system {
                Text("Copied")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.green, in: Capsule())
                    .offset(y: -24)
            }
        }
    }

    private var testFavorite: FavoriteLocation { currentSelectionFavorite }

    private func startMapRuntimeOnce() {
        guard !mapRuntimeDidStart else { return }
        mapRuntimeDidStart = true
        let pair = LastCoordinateStore.load()?.coordinatePair
            ?? CoordinatePair(
                mapCoordinate: mapState.selection.coordinate,
                mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
            )
        scheduleGeocode(pair: pair, revision: mapState.selection.revision)
    }

    @discardableResult
    private func reprojectMapSelection(for change: CoordinateConverter.MapCoordinateSystemChange) -> Bool {
        // Every current selection is persisted as a complete coordinate pair at
        // its input boundary. Replaying the matching stored representation
        // avoids a second GCJ/WGS conversion and its accumulated offset.
        guard let stored = LastCoordinateStore.load() else {
            RuntimeLogger.warning("APP", "Coordinate Conversion", "Current selection cache was unavailable during a map coordinate-system change")
            return false
        }
        mapState.reprojectSelectionForMapCoordinateSystemChange(stored.coordinate(for: change.current))
        RuntimeLogger.info("APP", "Coordinate Conversion", "Redisplayed the current selection from cached coordinate pairs after a coordinate-system change", details: [
            "from": change.previous.rawValue,
            "to": change.current.rawValue
        ])
        return true
    }

    private func applyRuntimeMapCoordinateSystemChange(
        _ change: CoordinateConverter.MapCoordinateSystemChange,
        reason: String
    ) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        searchRequestID &+= 1
        isSearching = false
        searchResults = []
        searchError = ""
        realtimeRequestTask?.cancel()
        realtimeRequestTask = nil
        realtimeRequestContext = nil
        mapState.clearRealtimeLocationForMapCoordinateSystemChange()
        let pinWasReprojected = reprojectMapSelection(for: change)
        if let stored = LastCoordinateStore.load() {
            scheduleGeocode(pair: stored.coordinatePair, revision: mapState.selection.revision)
        }
        RuntimeLogger.warning("APP", "Coordinate Conversion", "Map coordinate system changed", details: [
            "Trigger": reason,
            "Previous system": change.previous.diagnosticName,
            "New system": change.current.diagnosticName,
            "Pin reprojected": String(pinWasReprojected),
            "Blue-dot cache": "Cleared",
            "Search results": "Cleared",
            "Asynchronous geocoding": "Reset"
        ])
    }

    @discardableResult
    private func refreshRuntimeMapCoordinateSystem(reason: String) async -> Bool {
        let result = await CoordinateConverter.refreshRuntimeMapCoordinateSystem(reason: reason)
        guard !Task.isCancelled else { return false }
        switch result {
        case .changed(let change):
            applyRuntimeMapCoordinateSystemChange(change, reason: reason)
            return true
        case .unchanged:
            return true
        case .unavailable, .cancelled:
            return false
        }
    }

    private func scheduleBluePointMapCoordinateSystemRefresh() {
        guard mapCoordinateSystemRefreshTask == nil else {
            bluePointRefreshPending = true
            return
        }
        mapCoordinateSystemRefreshID &+= 1
        let refreshID = mapCoordinateSystemRefreshID
        mapCoordinateSystemRefreshTask = Task { @MainActor in
            defer {
                if refreshID == mapCoordinateSystemRefreshID {
                    let needsAnotherRefresh = bluePointRefreshPending && !Task.isCancelled
                    mapCoordinateSystemRefreshTask = nil
                    bluePointRefreshPending = false
                    if needsAnotherRefresh {
                        scheduleBluePointMapCoordinateSystemRefresh()
                    }
                }
            }
            // Coalesce the didUpdate/regionDidChange pair generated by one
            // native location sample without caching the probe result.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, refreshID == mapCoordinateSystemRefreshID else { return }
            var attempt = 0
            repeat {
                bluePointRefreshPending = false
                _ = await refreshRuntimeMapCoordinateSystem(reason: "New MapKit blue-dot sample")
                attempt += 1
            } while !Task.isCancelled
                && refreshID == mapCoordinateSystemRefreshID
                && bluePointRefreshPending
                && attempt < 2
        }
    }

    private func awaitCoordinatedMapCoordinateSystemRefresh(reason: String) async {
        if let pendingRefresh = mapCoordinateSystemRefreshTask {
            await pendingRefresh.value
            return
        }
        mapCoordinateSystemRefreshID &+= 1
        let refreshID = mapCoordinateSystemRefreshID
        let task = Task { @MainActor in
            _ = await refreshRuntimeMapCoordinateSystem(reason: reason)
        }
        mapCoordinateSystemRefreshTask = task
        await task.value
        if refreshID == mapCoordinateSystemRefreshID {
            mapCoordinateSystemRefreshTask = nil
        }
    }

    private func saveCurrentSelectionAsFavorite() {
        guard favoriteSaveTask == nil else { return }
        let snapshot = currentSelectionFavorite
        // Preserve the pair created when this selection entered the map. If
        // the runtime probe changes type, replay its other stored field instead
        // of reinterpreting the old visible coordinate as the new type.
        let pair = currentSelectionPair
        let selectionRevision = mapState.selection.revision
        favoriteSaveTask = Task { @MainActor in
            defer { favoriteSaveTask = nil }
            await awaitCoordinatedMapCoordinateSystemRefresh(reason: "Saving favorite")
            guard !Task.isCancelled else {
                return
            }
            guard mapState.selection.revision == selectionRevision else {
                RuntimeLogger.info("APP", "Coordinate Conversion", "Cancelled favorite save because the selection changed during detection")
                return
            }
            RuntimeLogger.info("APP", "Coordinate Conversion", "Saved current selection as a favorite", details: [
                "Current map coordinate system": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
                "Stored fields": "Global Standard (WGS-84) + China Standard (GCJ-02)"
            ])
            let favorite = favorites.save(
                name: snapshot.name,
                coordinatePair: pair,
                accuracy: snapshot.accuracy
            )
            mapState.selectFavorite(
                pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
                id: favorite.id,
                name: favorite.name
            )
            LastCoordinateStore.save(coordinatePair: pair, zoomMeters: mapState.viewportMeters)
        }
    }

    private func registerWiFiChangeObserver() {
        guard runtimeMode.mode == .localWiFi else { return }
        guard wifiChangeObserverToken == nil else { return }
        wifiChangeObserverToken = net.observeWiFiChanges { [self] reason in
            handleWiFiChange(reason: reason)
        }
    }

    private func refreshThirdPartyState() {
        guard runtimeMode.mode == .thirdParty,
              locationOperationTask == nil else { return }
        locationOperationTask = Task { @MainActor in
            do {
                let response = try await thirdPartyProxy.query()
                if response.success,
                   let latitude = response.latitude,
                   let longitude = response.longitude {
                    activeSpoofLat = latitude
                    activeSpoofLon = longitude
                    spoofState = .active
                } else if response.error?.contains("无已保存") == true || response.error?.localizedCaseInsensitiveContains("no saved") == true {
                    activeSpoofLat = nil
                    activeSpoofLon = nil
                    spoofState = .idle
                } else {
                    spoofState = .idle
                    RuntimeLogger.warning("APP", "ThirdPartyProxy", "Third-party proxy query returned a failure", details: [
                        "Client": thirdPartyClient.selectedClient.name,
                        "Request": "WLOC query",
                        "Error": response.error ?? "Unknown error"
                    ])
                    setup.requestThirdPartySetup(message: response.error ?? "Third-party proxy query failed")
                }
            } catch {
                spoofState = .idle
                RuntimeLogger.warning("APP", "ThirdPartyProxy", "Third-party proxy status query failed after launch", details: [
                    "Client": thirdPartyClient.selectedClient.name,
                    "Request": "WLOC query",
                    "Connection": String(describing: thirdPartyProxy.connectionState),
                    "Error": error.localizedDescription
                ])
                setup.requestThirdPartySetup(message: error.localizedDescription)
            }
            locationOperationTask = nil
        }
    }

    private func handleWiFiChange(reason: WiFiChangeReason) {
        RuntimeLogger.info("APP", "Wi-Fi", "Detected a Wi-Fi network change", details: [
            "Reason": reason.rawValue,
            "Virtual location enabled": String(spoofState == .active)
        ])
        guard spoofState == .active else { return }
        if wifiVerificationTask != nil {
            RuntimeLogger.info("APP", "Wi-Fi", "Network is still changing; restarting the environment-check delay")
        }
        wifiVerificationTask?.cancel()
        let verificationID = UUID()
        wifiVerificationID = verificationID
        wifiVerificationTask = Task { @MainActor in
            defer {
                if wifiVerificationID == verificationID {
                    wifiVerificationTask = nil
                    wifiVerificationID = nil
                }
            }
            let stabilizationNanoseconds: UInt64 = 3_000_000_000
            RuntimeLogger.info("APP", "Wi-Fi", "Waiting for Wi-Fi to stabilize before checking the environment", details: [
                "Wait seconds": "3",
                "Event reason": reason.rawValue
            ])
            do {
                try await Task.sleep(nanoseconds: stabilizationNanoseconds)
            } catch {
                RuntimeLogger.debug("APP", "Wi-Fi", "Delayed check cancelled by a newer network event")
                return
            }
            guard !Task.isCancelled, spoofState == .active else { return }
            guard net.isSatisfied, net.isWiFiEnabled else {
                RuntimeLogger.warning("APP", "Wi-Fi", "Wi-Fi is still unavailable after the stabilization delay; prompting for proxy setup", details: [
                    "Network available": String(net.isSatisfied),
                    "Wi-Fi interface": String(net.isWiFiEnabled)
                ])
                activeTip = nil
                setup.requestSetup(message: "No usable Wi-Fi connection is available. Connect to Wi-Fi, then configure the manual proxy at 127.0.0.1:8888.")
                return
            }

            // A manual diagnostics request can occupy the verifier for its full
            // eight-second URL timeout. Wait long enough to run this check after
            // it finishes instead of silently dropping the Wi-Fi-change check.
            let maximumAttempts = 11
            for attempt in 1...maximumAttempts {
                RuntimeLogger.info("APP", "Wi-Fi", "Starting background environment check", details: [
                    "Attempt": "\(attempt)/\(maximumAttempts)",
                    "SSID readable": String(net.currentSSID != nil)
                ])
                let result = await setup.runVerificationTest()
                guard !Task.isCancelled, spoofState == .active else { return }
                if result == .verificationInProgress, attempt < maximumAttempts {
                    RuntimeLogger.info("APP", "Wi-Fi", "Another environment check is running; retrying in 1 second", details: [
                        "Attempt": "\(attempt)/\(maximumAttempts)"
                    ])
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                RuntimeLogger.info("APP", "Wi-Fi", "Background environment check completed", details: [
                    "Result": result.id,
                    "success": String(result.isSuccess)
                ])
                if !result.isSuccess,
                   result != .verificationInProgress,
                   result != .verificationSuperseded {
                    activeTip = nil
                    setup.applyVerificationResult(result)
                } else if result == .verificationInProgress {
                    RuntimeLogger.warning("APP", "Wi-Fi", "Environment check remained busy; suppressing a duplicate alert")
                }
                return
            }
        }
    }

    private func requestRealtimeLocation() {
        guard realtimeButtonTask == nil else { return }
        realtimeButtonTask = Task { @MainActor in
            defer { realtimeButtonTask = nil }
            await awaitCoordinatedMapCoordinateSystemRefresh(reason: "Real-time location button tapped")
            guard !Task.isCancelled else {
                return
            }
            performRealtimeLocationRequest()
        }
    }

    private func performRealtimeLocationRequest() {
        let intent = mapState.beginRealtimeIntent()
        RuntimeLogger.info("APP", "Real-Time Location", "User requested real-time location", details: [
            "intentID": String(intent.id),
            "Selection revision": String(intent.selectionRevision),
            "Current map coordinate system": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "Blue-dot cache available": String(mapState.realtimeLocation != nil),
            "CLLocationManager request active": String(realtime.isRequesting)
        ])
        // 蓝点存在就直接用，不限时（MKMapView 的 userLocation 只在位置变化时才更新）
        if let loc = mapState.realtimeLocation {
            RealtimeLocationTrace.log("Real-time location button used the MapKit blue-dot cache directly", location: loc, details: [
                "intentID": String(intent.id),
                "Source": "MapLocationState.realtimeLocation"
            ])
            acceptRealtimeLocation(
                loc.coordinate,
                intent: intent,
                source: .mapKitBluePoint,
                sourceDescription: "MapKit blue-dot cache"
            )
            return
        }
        RuntimeLogger.info("APP", "Real-Time Location", "MapKit blue dot unavailable; starting CLLocationManager fallback", details: [
            "intentID": String(intent.id)
        ])
        startRealtimeLocationRequest(
            source: "CLLocationManager",
            showFailureAlert: true,
            intent: intent
        )
    }

    private func handleNativeRealtimeLocation(_ location: CLLocation) {
        mapState.updateRealtimeLocation(location)
        logSpoofCoordinateDiagnosisIfNeeded(location)
        scheduleBluePointMapCoordinateSystemRefresh()
        guard let context = realtimeRequestContext else {
            return
        }

        RealtimeLocationTrace.log("Home screen received the MapKit blue-dot callback needed by the pending request", location: location, details: [
            "Current selection revision": String(mapState.selection.revision)
        ])

        // MKMapView's MKUserLocation is the visible blue point. When it arrives,
        // fulfill the pending intent from that exact sample and cancel the slower
        // CLLocationManager fallback so the camera and dot cannot disagree.
        realtimeRequestContext = nil
        realtimeRequestTask?.cancel()
        RuntimeLogger.info("APP", "Real-Time Location", "MapKit blue dot completed the request first; cancelling CLLocationManager fallback", details: [
            "intentID": String(context.intent.id),
            "Original fallback source": context.source
        ])
        acceptRealtimeLocation(
            location.coordinate,
            intent: context.intent,
            source: .mapKitBluePoint,
            sourceDescription: "Blue dot (in progress) → \(context.source)"
        )
    }

    private func logSpoofCoordinateDiagnosisIfNeeded(_ location: CLLocation) {
        guard spoofState == .active,
              let latitude = activeSpoofLat,
              let longitude = activeSpoofLon else { return }
        let targetPair = CoordinateConverter.coordinatePair(
            lat: latitude,
            lon: longitude,
            mapCoordinateSystem: .wgs84
        )
        let diagnosis = CoordinateConverter.diagnoseRepresentation(
            sample: location.coordinate,
            pair: targetPair,
            maximumDistance: max(1_000, location.horizontalAccuracy * 4),
            minimumSeparation: max(30, location.horizontalAccuracy)
        )
        let shouldLog = !hasLoggedSpoofDiagnosis
            || diagnosis.inferredSystem != lastSpoofDiagnosisSystem
        guard shouldLog else { return }
        hasLoggedSpoofDiagnosis = true
        lastSpoofDiagnosisSystem = diagnosis.inferredSystem
        RuntimeLogger.info("APP", "Coordinate Conversion", "Determined MapKit blue-dot coordinate system after enabling virtual location", details: [
            "Current map coordinate system": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "WLOC target system": CoordinateConverter.MapCoordinateSystem.wgs84.diagnosticName,
            "Blue-dot sample is closer to": diagnosis.inferredName,
            "Distance to WGS target (meters)": String(format: "%.1f", diagnosis.distanceToWGS84),
            "Distance to GCJ target (meters)": String(format: "%.1f", diagnosis.distanceToGCJ02),
            "Logging policy": "First sample after each activation or when inference changes"
        ])
    }

    private func startRealtimeLocationRequest(
        source: String,
        showFailureAlert: Bool,
        intent suppliedIntent: RealtimeLocationIntent? = nil
    ) {
        let intent = suppliedIntent ?? mapState.beginRealtimeIntent()
        realtimeRequestContext = RealtimeLocationRequestContext(
            intent: intent,
            source: source,
            showFailureAlert: showFailureAlert
        )
        RuntimeLogger.info("APP", "Real-Time Location", "Registered real-time location request context", details: [
            "intentID": String(intent.id),
            "Selection revision": String(intent.selectionRevision),
            "Source": source,
            "Show failure alert": String(showFailureAlert),
            "Task already exists": String(realtimeRequestTask != nil),
            "Manager request active": String(realtime.isRequesting)
        ])

        // A button tap during the startup request retargets that same in-flight
        // Core Location request to the newer intent instead of being ignored.
        guard realtimeRequestTask == nil, !realtime.isRequesting else {
            RuntimeLogger.info("APP", "Real-Time Location", "Reusing active CLLocationManager request and updating its intent context", details: [
                "intentID": String(intent.id)
            ])
            return
        }
        realtimeRequestTask = Task { @MainActor in
            defer {
                realtimeRequestTask = nil
                realtimeRequestContext = nil
            }
            guard let coordinate = await realtime.requestLocation() else {
                RuntimeLogger.warning("APP", "Real-Time Location", "CLLocationManager fallback did not return coordinates", details: [
                    "Authorization raw value": String(realtime.authorizationStatus.rawValue),
                    "Task cancelled": String(Task.isCancelled),
                    "Context available": String(realtimeRequestContext != nil)
                ])
                guard let context = realtimeRequestContext,
                      context.showFailureAlert,
                      !Task.isCancelled,
                      mapState.selection.revision == context.intent.selectionRevision else { return }
                RuntimeLogger.info("APP", "Map", "Location request failed; status=\(realtime.authorizationStatus.rawValue)")
                showLocationAlert = true
                return
            }
            RealtimeLocationTrace.coordinate("Home screen received CLLocationManager fallback coordinates", coordinate: coordinate, details: [
                "Task cancelled": String(Task.isCancelled)
            ])
            guard !Task.isCancelled, let context = realtimeRequestContext else {
                RuntimeLogger.info("APP", "Real-Time Location", "Discarded CLLocationManager result because the task was cancelled or the blue dot finished first", details: [
                    "Task cancelled": String(Task.isCancelled),
                    "Context available": String(realtimeRequestContext != nil)
                ])
                return
            }
            acceptRealtimeLocation(
                coordinate,
                intent: context.intent,
                source: .coreLocation,
                sourceDescription: context.source
            )
        }
    }

    private func acceptRealtimeLocation(
        _ coordinate: CLLocationCoordinate2D,
        intent: RealtimeLocationIntent,
        source: RealtimeCoordinateSource,
        sourceDescription: String
    ) {
        let currentViewport = mapState.viewportMeters
        let sourceCoordinateSystem = source.coordinateSystem
        let pair = CoordinateConverter.coordinatePair(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            mapCoordinateSystem: sourceCoordinateSystem
        )
        let accepted = mapState.acceptRealtimeLocation(
            pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            intent: intent
        )
        RuntimeLogger.info("APP", "Real-Time Location", "Determined real-time coordinate system and submitted the location to the map", details: [
            "Source": sourceDescription,
            "Source type": source.diagnosticName,
            "Input coordinate system": sourceCoordinateSystem.diagnosticName,
            "intentID": String(intent.id),
            "Intent selection revision": String(intent.selectionRevision),
            "Current selection revision": String(mapState.selection.revision),
            "App-confirmed map coordinate system": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "accepted": String(accepted),
            "Displayed coordinate field": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "Stored fields": "WGS-84 + GCJ-02"
        ])
        RealtimeLocationTrace.coordinate("Original real-time location coordinates", coordinate: coordinate, details: [
            "Source": sourceDescription,
            "Input coordinate system": sourceCoordinateSystem.diagnosticName
        ])
        RealtimeLocationTrace.coordinate("Coordinates actually displayed on the map", coordinate: pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem), details: [
            "Map coordinate system": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        guard accepted else { return }
        // 用点击时的缩放级别居中，不改变缩放
        mapState.focusSelection(distanceMeters: currentViewport)
        // Persist both forms once from the explicitly typed input boundary.
        LastCoordinateStore.save(coordinatePair: pair, zoomMeters: currentViewport)
        favorites.selectMatching(coordinatePair: pair)
        scheduleGeocode(pair: pair, revision: mapState.selection.revision)
    }

    private func scheduleGeocode(pair: CoordinatePair, revision: UInt64) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        geocodeDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, mapState.selection.revision == revision else { return }
            reverseGeocode(pair, revision: revision)
        }
    }

    private func reverseGeocode(_ pair: CoordinatePair, revision: UInt64) {
        reverseGeocodeTask?.cancel()
        let wgsCoordinate = pair.wgs84.coordinate
        let mapCoordinate = pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
        let location = CLLocation(latitude: wgsCoordinate.latitude, longitude: wgsCoordinate.longitude)
        reverseGeocodeTask = Task { @MainActor in
            let retryDelays: [UInt64] = [0, 800_000_000, 1_600_000_000]
            var lastError: Error?

            for (attempt, delay) in retryDelays.enumerated() {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                }
                guard !Task.isCancelled, mapState.selection.revision == revision else { return }

                do {
                    // 并⾏获取：CLGeocoder（地址结构化） + MKLocalSearch（地图显⽰名称）
                    // MKLocalSearch 在无结果时抛错，不可与 CLGeocoder 共用 try await 导致互相影响
                    async let clPlacemarks = CLGeocoder().reverseGeocodeLocation(location)
                    let mkRequest = MKLocalSearch.Request()
                    mkRequest.region = MKCoordinateRegion(center: mapCoordinate, latitudinalMeters: 400, longitudinalMeters: 400)
                    let mkResponse = try? await MKLocalSearch(request: mkRequest).start()

                    let placemarks = try await clPlacemarks
                    guard !Task.isCancelled,
                          mapState.selection.revision == revision,
                          let placemark = placemarks.first else { return }

                    if mkResponse?.mapItems.first != nil {
                        RuntimeLogger.info("APP", "Geocode", "MKLocalSearch returned a place result")
                    }
                    let mapItemName = mkResponse?.mapItems.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mapItemPOI = mkResponse?.mapItems.first?.placemark.areasOfInterest?.first
                    // 优先使⽤ MKLocalSearch 结果（与地图显⽰一致），CLGeocoder 作为 fallback
                    let poi = { () -> String? in
                        if let v = mapItemPOI?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                        if let v = mapItemName?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                        return placemark.areasOfInterest?.first ?? placemark.name
                    }()
                    let streetAddress = [placemark.thoroughfare, placemark.subThoroughfare]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let descriptor = MapPlaceDescriptor(
                        pointOfInterest: poi,
                        streetAddress: streetAddress,
                        road: placemark.thoroughfare,
                        neighborhood: placemark.subLocality,
                        district: placemark.subLocality ?? placemark.subAdministrativeArea,
                        city: placemark.locality ?? placemark.subAdministrativeArea,
                        province: placemark.administrativeArea,
                        country: placemark.country
                    )
                    _ = mapState.acceptPlaceDescriptor(descriptor, selectionRevision: revision)
                    return
                } catch {
                    guard !Task.isCancelled, mapState.selection.revision == revision else { return }
                    lastError = error
                    let nsError = error as NSError
                    let isNetworkError = nsError.domain == kCLErrorDomain
                        && nsError.code == CLError.network.rawValue
                    guard isNetworkError, attempt < retryDelays.count - 1 else { break }
                    RuntimeLogger.info("APP", "Geocode", "Reverse-geocoding network request failed; preparing to retry", details: [
                        "attempt": String(attempt + 1),
                        "revision": String(revision)
                    ])
                }
            }

            guard !Task.isCancelled,
                  mapState.selection.revision == revision,
                  let lastError else { return }
            RuntimeLogger.warning("APP", "Geocode", "Reverse geocoding failed", details: [
                "error": lastError.localizedDescription,
                "revision": String(revision)
            ])
        }
    }

    private func doSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        searchRequestID &+= 1
        let requestID = searchRequestID
        isSearching = true
        searchError = ""
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                guard requestID == searchRequestID else { return }
                isSearching = false
                if let error {
                    searchResults = []
                    searchError = error.localizedDescription
                    return
                }
                searchResults = (response?.mapItems ?? []).prefix(6).map { item in
                    let r = SearchLocationResult(
                        name: item.name ?? "Unnamed Location",
                        subtitle: [item.placemark.locality, item.placemark.subLocality, item.placemark.thoroughfare]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        coordinate: item.placemark.coordinate
                    )
                    RuntimeLogger.info("APP", "Search", "Received search result", details: [
                        "Name": r.name
                    ])
                    return r
                }
                if searchResults.isEmpty { searchError = "No matching places were found." }
            }
        }
    }

    private func selectSearchResult(_ result: SearchLocationResult) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(nil)
        mapState.selectSearchResult(result.coordinate, name: result.name)
        LastCoordinateStore.save(
            mapCoordinate: result.coordinate,
            mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem,
            zoomMeters: mapState.viewportMeters
        )
        searchText = result.name
        searchResults = []
        searchError = ""
    }

    private func deleteSearchResult(_ result: SearchLocationResult) {
        searchResults.removeAll { $0.id == result.id }
    }

    private func select(_ favorite: FavoriteLocation) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(favorite.id)
        RuntimeLogger.info("APP", "Coordinate Conversion", "Selected a favorite and displayed it on the map", details: [
            "Current map coordinate system": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "Map source field": CoordinateConverter.currentMapCoordinateSystem == .gcj02 ? "coordinatePair.gcj02" : "coordinatePair.wgs84",
            "Stored data": "Global Standard (WGS-84) + China Standard (GCJ-02)"
        ])
        mapState.selectFavorite(
            favorite.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            id: favorite.id,
            name: favorite.name
        )
        LastCoordinateStore.save(
            coordinatePair: favorite.coordinatePair,
            zoomMeters: mapState.viewportMeters
        )
    }

    private var enableTipSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ActivationTipContent(runtimeMode: runtimeMode.mode, dismiss: {})
                }.padding(16)
            }
            .navigationTitle("Virtual Location Enabled").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if tipPreferences.canSuppress(.activation) {
                        Button {
                            tipPreferences.suppress(.activation)
                            showEnableTip = false
                        } label: {
                            Label("Don't Remind Me Again", systemImage: "bell.slash.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button { showEnableTip = false } label: {
                            Text("Got It")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button { showEnableTip = false } label: {
                            Text("Got It")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private var disableTipSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DeactivationTipContent(runtimeMode: runtimeMode.mode, dismiss: {})
                    if runtimeMode.mode == .localWiFi {
                        RemoveProxyTipContent(dismiss: {})
                    }
                }.padding(16)
            }
            .navigationTitle("Virtual Location Disabled").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if tipPreferences.canSuppress(.deactivation) {
                        Button {
                            tipPreferences.suppress(.deactivation)
                            showDisableTip = false
                        } label: {
                            Label("Don't Remind Me Again", systemImage: "bell.slash.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button { showDisableTip = false } label: {
                            Text("Got It")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button { showDisableTip = false } label: {
                            Text("Got It")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}
