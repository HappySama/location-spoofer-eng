import SwiftUI

private enum UpdateCheckResult: Identifiable {
    case current(currentVersion: String, latestVersion: String)
    case available(AppUpdatePrompt)
    case failed

    var id: String {
        switch self {
        case .current(let currentVersion, let latestVersion):
            return "current-\(currentVersion)-\(latestVersion)"
        case .available(let prompt):
            return "available-\(prompt.id)"
        case .failed:
            return "failed"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var actions: LocationActionCoordinator
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject private var motionSimulation = MotionSimulationStore.shared
    @ObservedObject private var moduleSource = ThirdPartyModuleSourceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var activeTip: TipKind?
    @State private var proxyOperationError = ""
    @State private var proxyOperationAlertTitle = "Proxy Operation Failed"
    @State private var modeOperationRunning = false
    @State private var copiedClient: ThirdPartyProxyClient?
    @State private var copiedMITMHostnames = false
    @State private var showCertificateResetConfirmation = false
    @State private var githubDestination: SafariDestination?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckResult: UpdateCheckResult?

    var body: some View {
        Form {
            Section("Runtime Mode") {
                Picker("Mode", selection: runtimeModeBinding) {
                    ForEach(ProxyRuntimeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(modeOperationRunning || actions.state.isBusy || thirdPartyProxy.isRequesting)

            }

            Section("Status") {
                if runtimeMode.mode == .localWiFi {
                    HStack {
                        Label("Local Proxy", systemImage: proxy.isRunning ? "play.circle.fill" : "stop.circle")
                        Spacer()
                        Toggle("", isOn: proxyBinding).labelsHidden()
                            .tint(.blue)
                            .disabled(actions.state.isBusy)
                    }
                } else {
                    HStack {
                        Label("Third-Party Module", systemImage: thirdPartyStatusIcon)
                        Spacer()
                        Text(thirdPartyStatusText).foregroundStyle(.secondary)
                    }
                    Button {
                        detectThirdPartyConnection()
                    } label: {
                        if thirdPartyProxy.isRequesting {
                            HStack { ProgressView(); Text("Testing…") }
                        } else {
                            Label("Test Connection", systemImage: "network")
                        }
                    }
                    .disabled(thirdPartyProxy.isRequesting)
                }
                HStack {
                    Label("Virtual Location", systemImage: virtualLocationIsActive ? "location.fill" : "location.slash")
                    Spacer()
                    Text(virtualLocationStatusText).foregroundStyle(.secondary)
                }
            }

            Section("Location Simulation") {
                Toggle("Simulate Motion State", isOn: motionSimulationBinding)
                    .disabled(
                        modeOperationRunning ||
                        actions.state.isBusy ||
                        thirdPartyProxy.isRequesting
                    )
                Text("Experimental and disabled by default. When enabled, motion state is also simulated in location responses.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if runtimeMode.mode == .thirdParty {
                thirdPartyConfigurationSection
            } else {
                Section("Instructions") {
                    Button {
                        activeTip = .activation
                    } label: {
                        Label("How to Enable", systemImage: "checklist")
                    }
                    Button {
                        activeTip = .deactivation
                    } label: {
                        Label("How to Restore Real Location", systemImage: "arrow.uturn.backward.circle")
                    }
                    Button {
                        activeTip = .removeProxy
                    } label: {
                        Label("Remove the Wi-Fi Proxy", systemImage: "wifi.slash")
                    }
                }

            }

            Section("How It Works") {
                Text(workflowDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("App") {
                if runtimeMode.mode == .localWiFi {
                    Button {
                        setup.requestSetup()
                    } label: {
                        Label("Open Setup Guide", systemImage: "arrow.clockwise.circle")
                    }
                }
                Button {
                    checkForUpdates()
                } label: {
                    if isCheckingForUpdates {
                        HStack {
                            ProgressView()
                            Text("Checking…")
                        }
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isCheckingForUpdates)
                valueRow("Version", value: versionText)
            }

            if runtimeMode.mode == .localWiFi {
                Section("Certificate") {
                    Button(role: .destructive) {
                        showCertificateResetConfirmation = true
                    } label: {
                        Label("Reset Certificate", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(modeOperationRunning || actions.state.isBusy)

                    Text("This deletes only the device CA stored in the app's Keychain. You must remove the previously installed certificate manually from iOS Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Support") {
                NavigationLink {
                    BugReportView(setup: setup)
                } label: {
                    Label("Report a Bug", systemImage: "ladybug")
                }

                Button {
                    githubDestination = SafariDestination(url: GitHubSubmission.usageHelpURL)
                } label: {
                    Label("User Guide", systemImage: "questionmark.circle")
                }

                Button {
                    githubDestination = SafariDestination(url: GitHubSubmission.featureRequestURL)
                } label: {
                    Label("Request a Feature", systemImage: "lightbulb")
                }

                if runtimeMode.mode == .thirdParty {
                    Button {
                        UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                            for: thirdPartyClient.selectedClient,
                            systemVersion: UIDevice.current.systemVersion
                        )
                        githubDestination = SafariDestination(
                            url: GitHubSubmission.communityContributionURL
                        )
                    } label: {
                        Label("Share a Third-Party Configuration", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("About") {
                Button {
                    if let url = URL(string: "https://github.com/xweiba/location-spoofer") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("xweiba/location-spoofer", systemImage: "link")
                }
                Text("If you find this app useful, consider starring the project on GitHub.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Acknowledgements") {
                Button {
                    if let url = URL(string: "https://github.com/Yu9191/wloc") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Core location-modification logic adapted from Yu9191/wloc", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
        }
        .sheet(item: $activeTip) { kind in
            TipSheetView(kind: kind)
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
        .alert(proxyOperationAlertTitle, isPresented: Binding(
            get: { !proxyOperationError.isEmpty },
            set: { if !$0 { proxyOperationError = "" } }
        )) {
            Button("Got It", role: .cancel) {}
        } message: {
            Text(proxyOperationError)
        }
        .alert(item: $updateCheckResult) { result in
            updateCheckAlert(for: result)
        }
        .confirmationDialog(
            "Reset the Certificate?",
            isPresented: $showCertificateResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset and Generate a New Certificate", role: .destructive) {
                resetCertificateAuthority()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current virtual location and local proxy will stop. The app will delete its device CA from the Keychain, immediately generate a new certificate, and open the installation guide. You must also go to Settings → General → VPN & Device Management, manually remove the old certificate, then install and fully trust the new one.")
        }
        .task(id: runtimeMode.mode) {
            guard runtimeMode.mode == .thirdParty, !modeOperationRunning else { return }
            if !(await thirdPartyProxy.refreshAdvancedFeatureAvailability()) {
                disableUnsupportedThirdPartyMotionSimulation()
            }
        }
        .onChange(of: thirdPartyProxy.moduleUpdateRecommended) { updateRecommended in
            guard updateRecommended else { return }
            disableUnsupportedThirdPartyMotionSimulation()
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).font(.footnote.monospaced()).foregroundStyle(.secondary) }
    }

    private var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task { @MainActor in
            defer { isCheckingForUpdates = false }
            guard let configuration = await AppRemoteConfigurationService.fetch() else {
                updateCheckResult = .failed
                return
            }
            AppRemoteConfigurationStore.shared.apply(configuration)
            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? AppRemoteConfiguration.fallback.latestVersion
            guard let pendingPrompt = configuration.updatePrompt(currentVersion: currentVersion) else {
                updateCheckResult = .current(
                    currentVersion: currentVersion,
                    latestVersion: configuration.latestVersion
                )
                return
            }
            let releaseNotes = await AppRemoteConfigurationService.fetchReleaseNotes(
                version: pendingPrompt.latestVersion
            )
            let prompt = configuration.updatePrompt(
                currentVersion: currentVersion,
                releaseNotes: releaseNotes
            ) ?? pendingPrompt
            updateCheckResult = .available(prompt)
        }
    }

    private func updateCheckAlert(for result: UpdateCheckResult) -> Alert {
        switch result {
        case .current(let currentVersion, let latestVersion):
            return Alert(
                title: Text("You're Up to Date"),
                message: Text("Installed version: \(currentVersion). Latest available version: \(latestVersion)."),
                dismissButton: .default(Text("Got It"))
            )
        case .available(let prompt):
            let details = prompt.releaseNotes
                ?? "Release notes are temporarily unavailable. Open the latest Release page for details."
            let message: String
            if prompt.requirement == .required {
                message = "Version \(prompt.currentVersion) is no longer supported. Update to \(prompt.latestVersion) to continue.\n\n\(details)"
            } else {
                message = "Installed version: \(prompt.currentVersion). Latest version: \(prompt.latestVersion).\n\n\(details)"
            }
            return Alert(
                title: Text(prompt.requirement == .required ? "Update Required" : "Update Available"),
                message: Text(message),
                primaryButton: .default(Text("Open Download Page")) {
                    UIApplication.shared.open(AppRemoteConfigurationService.releasesURL)
                },
                secondaryButton: .cancel(Text("Later"))
            )
        case .failed:
            return Alert(
                title: Text("Update Check Failed"),
                message: Text("Unable to retrieve version information. Check your internet connection and try again."),
                dismissButton: .default(Text("Got It"))
            )
        }
    }

    private var proxyBinding: Binding<Bool> {
        Binding(get: { proxy.isRunning }, set: { on in
            Task {
                if on {
                    do {
                        try await proxy.start()
                    } catch {
                        proxy.error = error.localizedDescription
                        proxyOperationAlertTitle = "Proxy Operation Failed"
                        proxyOperationError = error.localizedDescription
                    }
                } else {
                    if actions.virtualLocationEnabled {
                        actions.clear()
                        RuntimeLogger.info("APP", "Settings", "Disabled virtual location before stopping the proxy")
                    }
                    proxy.stop()
                }
            }
        })
    }

    private var runtimeModeBinding: Binding<ProxyRuntimeMode> {
        Binding(
            get: { runtimeMode.mode },
            set: { newMode in switchRuntimeMode(to: newMode) }
        )
    }

    private var motionSimulationBinding: Binding<Bool> {
        Binding(
            get: { motionSimulation.isEnabled },
            set: { enabled in
                if runtimeMode.mode == .localWiFi {
                    proxy.applyMotionSimulation(enabled)
                    return
                }
                guard thirdPartyProxy.activeSettings?.success == true else {
                    guard enabled else {
                        motionSimulation.setEnabled(false)
                        return
                    }
                    modeOperationRunning = true
                    Task { @MainActor in
                        if await thirdPartyProxy.refreshAdvancedFeatureAvailability() {
                            motionSimulation.setEnabled(true)
                        } else {
                            presentMotionSimulationModuleUpdateAlert()
                        }
                        modeOperationRunning = false
                    }
                    return
                }
                modeOperationRunning = true
                Task { @MainActor in
                    do {
                        _ = try await thirdPartyProxy.updateMotionSimulation(enabled)
                        motionSimulation.setEnabled(enabled)
                    } catch {
                        RuntimeLogger.error(
                            "APP",
                            "ThirdPartyProxy",
                            "Failed to synchronize the motion-state setting",
                            error: error,
                            details: ["Client": thirdPartyClient.selectedClient.name]
                        )
                        if error as? ThirdPartyProxyError == .moduleOutdated {
                            presentMotionSimulationModuleUpdateAlert()
                        } else {
                            setup.requestThirdPartySetup(message: error.localizedDescription)
                        }
                    }
                    modeOperationRunning = false
                }
            }
        )
    }

    @ViewBuilder
    private var thirdPartyConfigurationSection: some View {
        Section("Third-Party Proxy Configuration") {
            Picker("Client", selection: Binding(
                get: { thirdPartyClient.selectedClient },
                set: { thirdPartyClient.select($0) }
            )) {
                ForEach(ThirdPartyProxyClient.allCases) { client in
                    Text(client.name).tag(client)
                }
            }

            Toggle("Use the China Mirror for Module Downloads", isOn: Binding(
                get: { moduleSource.useMirror },
                set: { moduleSource.setUseMirror($0) }
            ))
            Text("This affects only module URLs copied from now on. Reimport an already installed module to switch its source.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if thirdPartyProxy.moduleUpdateRecommended {
                Text("The installed module is outdated. Basic coordinate spoofing still works, but version detection and motion-state simulation require the latest module.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let verificationText = thirdPartyClient.selectedClient.verificationText {
                HStack {
                    Text("Verification Status")
                    Spacer()
                    Text(verificationText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Button {
                UIPasteboard.general.string = thirdPartyClient.selectedClient.subscriptionURL.absoluteString
                copiedClient = thirdPartyClient.selectedClient
            } label: {
                Label(copiedClient == thirdPartyClient.selectedClient ? "Module URL Copied" : "Copy Module URL", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = ThirdPartyProxyManager.interceptionHostnamesText
                copiedMITMHostnames = true
            } label: {
                Label(copiedMITMHostnames ? "Hostnames Copied" : "Copy Both MITM Hostnames", systemImage: "doc.on.doc")
            }

            Button {
                openThirdPartyClient(thirdPartyClient.selectedClient)
            } label: {
                Label("Open \(thirdPartyClient.selectedClient.name)", systemImage: "arrow.up.forward.app")
            }

            Button {
                setup.requestThirdPartyOnboarding()
                dismiss()
            } label: {
                Label("Reopen Configuration Guide", systemImage: "arrow.clockwise.circle")
            }

            if thirdPartyClient.selectedClient == .egern {
                Text("Egern uses Surge's .sgmodule file directly.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if thirdPartyClient.selectedClient == .stash {
                Text("Subscribe to the .stoverride file directly in Stash; do not convert it through Script Hub.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Text("After copying the module URL, add it as a module or rewrite subscription in the selected proxy client, then enable MITM for gs-loc.apple.com and gs-loc-cn.apple.com. Once the client saves coordinates, it keeps them active even when Location Spoofer is closed.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var thirdPartyStatusIcon: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "questionmark.circle"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var thirdPartyStatusText: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "Not Tested"
        case .connected(let active): return active ? "Connected, Coordinates Saved" : "Connected, No Coordinates"
        case .failed: return "Connection Failed"
        }
    }

    private var virtualLocationStatusText: String {
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled ? "Enabled" : "Disabled"
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active ? "Saved by Third-Party Client" : "Not Saved"
        }
        return "Unknown"
    }

    private var workflowDescription: String {
        if runtimeMode.mode == .thirdParty {
            return "The app selects map locations, stores favorites, and sends WGS-84 coordinates. The third-party proxy client intercepts Apple WLOC requests through its module and stores the selected coordinates. This mode does not start the app's local proxy, use its CA certificate, or require 127.0.0.1:8888."
        }
        return """
        The app runs a proxy server locally on this iPhone at 127.0.0.1:8888.

        The manual Wi-Fi proxy sends requests to gs-loc.apple.com and gs-loc-cn.apple.com through this local server. Using the installed CA certificate, the proxy decrypts the HTTPS traffic, replaces the coordinates in Apple's location response with your selected virtual coordinates, then encrypts the response and returns it to iOS.
        """
    }

    private func switchRuntimeMode(to newMode: ProxyRuntimeMode) {
        guard newMode != runtimeMode.mode, !modeOperationRunning else { return }
        modeOperationRunning = true
        Task { @MainActor in
            defer { modeOperationRunning = false }
            switch newMode {
            case .thirdParty:
                if actions.virtualLocationEnabled { actions.clear() }
                proxy.stop()
                setup.completeSetup()
                runtimeMode.setMode(.thirdParty)
                if runtimeMode.isInitialized(.thirdParty) {
                    do {
                        _ = try await thirdPartyProxy.validateConnection()
                        refreshThirdPartyAdvancedFeatures()
                        proxyOperationAlertTitle = "Mode Changed"
                        proxyOperationError = "Third-Party Proxy Mode passed its connection test. Remove the 127.0.0.1:8888 manual proxy from Wi-Fi to prevent both modes from intercepting the same request."
                    } catch {
                        openThirdPartySetup(for: error)
                    }
                } else {
                    setup.requestThirdPartyOnboarding()
                    dismiss()
                }
            case .localWiFi:
                do {
                    try await thirdPartyProxy.clear()
                } catch {
                    RuntimeLogger.warning("APP", "Mode", "Unable to clear third-party coordinates before switching to App Mode", details: [
                        "Error": error.localizedDescription
                    ])
                }
                runtimeMode.setMode(.localWiFi)
                await setup.prepareLocalServices()
                if runtimeMode.isInitialized(.localWiFi) {
                    let result = await setup.runVerificationTest()
                    setup.applyVerificationResult(result)
                    if result.isSuccess {
                        proxyOperationAlertTitle = "Mode Changed"
                        proxyOperationError = "App Mode passed its environment check. Disable the third-party WLOC module or disconnect that proxy to prevent both modes from intercepting the same request."
                    } else {
                        dismiss()
                    }
                } else {
                    setup.requestSetup()
                    dismiss()
                }
            }
        }
    }

    private func detectThirdPartyConnection() {
        let client = thirdPartyClient.selectedClient
        let startedAt = Date()
        Task { @MainActor in
            do {
                _ = try await thirdPartyProxy.validateConnection()
                refreshThirdPartyAdvancedFeatures()
                RuntimeLogger.info("APP", "ThirdPartyProxy", "Third-party connection test passed from Settings", details: [
                    "Client": client.name,
                    "Request": "WLOC query",
                    "Elapsed milliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ])
                runtimeMode.markInitialized(.thirdParty)
            } catch {
                RuntimeLogger.error(
                    "APP",
                    "ThirdPartyProxy",
                    "Third-party connection test failed from Settings",
                    error: error,
                    details: [
                        "Client": client.name,
                        "Request": "WLOC query",
                        "Connection": String(describing: thirdPartyProxy.connectionState),
                        "Elapsed milliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                        "Suggested fix": ThirdPartyProxyError.recoverySuggestion(for: error)
                    ]
                )
                openThirdPartySetup(for: error)
            }
        }
    }

    private func refreshThirdPartyAdvancedFeatures() {
        Task { @MainActor in
            if !(await thirdPartyProxy.refreshAdvancedFeatureAvailability()) {
                disableUnsupportedThirdPartyMotionSimulation()
            }
        }
    }

    private func presentMotionSimulationModuleUpdateAlert() {
        disableUnsupportedThirdPartyMotionSimulation()
        proxyOperationAlertTitle = "Unable to Enable Motion Simulation"
        proxyOperationError = "The installed module does not support motion-state simulation. Reimport the latest module before enabling it. Basic coordinate spoofing still works."
    }

    private func disableUnsupportedThirdPartyMotionSimulation() {
        guard runtimeMode.mode == .thirdParty else { return }
        motionSimulation.setEnabled(false)
    }

    private func openThirdPartySetup(for error: Error) {
        setup.requestThirdPartySetup(message: error.localizedDescription)
        dismiss()
    }

    private func resetCertificateAuthority() {
        guard runtimeMode.mode == .localWiFi, !modeOperationRunning else { return }
        modeOperationRunning = true
        Task { @MainActor in
            defer { modeOperationRunning = false }
            if actions.virtualLocationEnabled {
                actions.clear()
            }
            proxy.stop()
            do {
                try setup.certificateStore.reset()
                runtimeMode.resetInitialization(.localWiFi)
                guard await setup.prepareLocalServices() else {
                    proxyOperationAlertTitle = "Certificate Reset Failed"
                    proxyOperationError = setup.message
                    return
                }
                setup.requestCertificateSetup()
                dismiss()
            } catch {
                proxyOperationAlertTitle = "Certificate Reset Failed"
                proxyOperationError = error.localizedDescription
            }
        }
    }

    private func openThirdPartyClient(_ client: ThirdPartyProxyClient) {
        guard let url = client.launchURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                proxyOperationAlertTitle = "Unable to Open Client"
                proxyOperationError = "Unable to open \(client.name). Confirm that it is installed, then open it manually."
            }
        }
    }

    private var virtualLocationIsActive: Bool {
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active
        }
        return false
    }
}
