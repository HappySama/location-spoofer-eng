import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var setup = SetupCoordinator()
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @State private var phase: AppPhase = .splash
    @State private var updatePrompt: AppUpdatePrompt?
    @State private var requiredUpdatePrompt: AppUpdatePrompt?

    enum AppPhase { case splash, setup, map }

    var body: some View {
        Group {
            switch phase {
            case .splash:
                VStack(spacing: 16) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 48)).foregroundStyle(.blue)
                    ProgressView()
                    Text(runtimeMode.hasSelectedMode && runtimeMode.mode == .localWiFi
                         ? "Initializing the map and local proxy…"
                         : "Initializing the map…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            case .setup:
                FirstSetupView(setup: setup, onComplete: finishInitialSetup)
            case .map:
                NavigationView {
                    MapHomeView(setup: setup)
                }
                .fullScreenCover(isPresented: $setup.needsSetup) {
                    FirstSetupView(setup: setup, onComplete: finishPresentedSetup)
                }
            }
        }
        .task { await bootstrap() }
        .task { await checkForUpdates() }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active, let requiredUpdatePrompt else { return }
            updatePrompt = requiredUpdatePrompt
        }
        .alert(item: $updatePrompt) { prompt in
            updateAlert(for: prompt)
        }
    }

    @MainActor
    private func bootstrap() async {
        guard runtimeMode.hasSelectedMode else {
            ProxyManager.shared.stop()
            RuntimeLogger.info("APP", "Startup", "No runtime mode selected; skipping local CA and proxy initialization")
            setup.requestModeSelection()
            phase = .setup
            return
        }

        let launchMode = runtimeMode.mode
        guard runtimeMode.isInitialized(launchMode) else {
            if launchMode == .localWiFi {
                await setup.prepareLocalServices()
                setup.requestSetup()
            } else {
                ProxyManager.shared.stop()
                BackgroundKeepAlive.shared.stop()
                setup.requestThirdPartyOnboarding()
            }
            phase = .setup
            return
        }

        if launchMode == .localWiFi {
            await setup.prepareLocalServices()
        } else {
            ProxyManager.shared.stop()
            BackgroundKeepAlive.shared.stop()
            RuntimeLogger.info("APP", "Startup", "Third-party proxy mode: skipping the local CA, proxy, and environment check")
        }
        do {
            try CoordinateStorageMigration.migrateIfNeeded(favorites: FavoriteLocationStore())
        } catch {
            RuntimeLogger.error("APP", "Startup", "Legacy coordinate migration failed; it will be retried on the next launch", error: error)
        }

        // MapHomeView is intentionally constructed only after this required
        // coordinate-system gate resolves, so cached pins are never replayed
        // into an unknown Apple Maps coordinate system.
        let mapCoordinateSystem = await CoordinateConverter.resolveInitialMapCoordinateSystem()
        guard !Task.isCancelled else { return }
        RuntimeLogger.info("APP", "Startup", "Map coordinate-system initialization completed; continuing startup", details: [
            "Map coordinate system": mapCoordinateSystem.rawValue,
            "Used fallback": String(CoordinateConverter.initialMapCoordinateSystemUsedFallback)
        ])

        // Resolve the first map center before constructing MapHomeView. This
        // prevents a Shenzhen/cache frame followed by a second realtime frame.
        if LastCoordinateStore.load() == nil {
            RuntimeLogger.info("APP", "Startup", "No saved pin; requesting real-time location before creating the map")
            if let realtime = await RealtimeLocationManager.shared.requestLocation() {
                let mapCoordinateSystemChange = CoordinateConverter.correctMapCoordinateSystemUsingRealtime(realtime)
                let pair = CoordinateConverter.coordinatePair(
                    lat: realtime.latitude,
                    lon: realtime.longitude,
                    mapCoordinateSystem: .wgs84
                )
                LastCoordinateStore.save(coordinatePair: pair, zoomMeters: 1_000)
                RuntimeLogger.info("APP", "Startup", "Prepared the initial map state using real-time location", details: [
                    "Map coordinate system": CoordinateConverter.currentMapCoordinateSystem.rawValue,
                    "Corrected fallback system": String(mapCoordinateSystemChange != nil),
                    "Zoom meters": "1000"
                ])
                RealtimeLocationTrace.coordinate(
                    "Initial real-time location obtained before map creation (WGS-84)",
                    coordinate: realtime
                )
            } else {
                RuntimeLogger.warning("APP", "Startup", "Unable to obtain real-time location before map creation; using Shenzhen as the initial location", details: [
                    "Map coordinate system": mapCoordinateSystem.rawValue,
                    "Zoom meters": "1000"
                ])
            }
        } else {
            RuntimeLogger.info("APP", "Startup", "Saved pin found; prepared the initial map state directly")
        }
        guard !Task.isCancelled else { return }

        setup.completeSetup()
        RuntimeLogger.info("APP", "Startup", "All startup prerequisites completed; creating MapHomeView")
        phase = .map
    }

    private func finishInitialSetup() {
        let completedMode = runtimeMode.mode
        runtimeMode.markInitialized(completedMode)
        setup.completeSetup()
        phase = .splash
        Task { await bootstrap() }
    }

    private func finishPresentedSetup() {
        runtimeMode.markInitialized(runtimeMode.mode)
        setup.completeSetup()
    }

    @MainActor
    private func checkForUpdates() async {
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? AppRemoteConfiguration.fallback.latestVersion
        let configuration: AppRemoteConfiguration
        if let remote = await AppRemoteConfigurationService.fetch() {
            remoteConfiguration.apply(remote)
            configuration = remote
        } else {
            configuration = remoteConfiguration.configuration
        }
        guard let pendingPrompt = configuration.updatePrompt(currentVersion: currentVersion) else { return }
        let releaseNotes = await AppRemoteConfigurationService.fetchReleaseNotes(
            version: pendingPrompt.latestVersion
        )
        guard !Task.isCancelled,
              let prompt = configuration.updatePrompt(
                currentVersion: currentVersion,
                releaseNotes: releaseNotes
              ) else {
            return
        }
        if prompt.requirement == .required {
            requiredUpdatePrompt = prompt
        }
        updatePrompt = prompt
    }

    private func updateAlert(for prompt: AppUpdatePrompt) -> Alert {
        switch prompt.requirement {
        case .required:
            let details = prompt.releaseNotes
                ?? "Release notes are temporarily unavailable. Open the latest Release page for details."
            return Alert(
                title: Text("Update Required"),
                message: Text(
                    "Version \(prompt.currentVersion) is no longer supported. Update to \(prompt.latestVersion) to continue.\n\n\(details)"
                ),
                dismissButton: .default(Text("Update Now")) {
                    openUpdatePage(requiredPrompt: prompt)
                }
            )
        case .recommended:
            let details = prompt.releaseNotes
                ?? "Release notes are temporarily unavailable. Open the latest Release page for details."
            return Alert(
                title: Text("Update Available"),
                message: Text(
                    "Installed version: \(prompt.currentVersion). Latest version: \(prompt.latestVersion).\n\n\(details)"
                ),
                primaryButton: .default(Text("Open Download Page")) {
                    openUpdatePage(requiredPrompt: nil)
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
    }

    private func openUpdatePage(requiredPrompt: AppUpdatePrompt?) {
        UIApplication.shared.open(AppRemoteConfigurationService.releasesURL)
        guard requiredPrompt != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            updatePrompt = self.requiredUpdatePrompt
        }
    }
}
