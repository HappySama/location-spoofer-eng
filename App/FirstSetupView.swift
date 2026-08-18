import SwiftUI
import UIKit

private struct SetupScreenshotPreview: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

private struct CertificateDownloadDestination: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ThirdPartyConnectionTestFailure {
    let message: String
}

enum SetupStep: Int, CaseIterable {
    case mode
    case proxy
    case cert
    case thirdPartyClient
    case thirdPartyImport

    var title: String {
        switch self {
        case .mode: return "Choose Mode"
        case .proxy: return "Wi-Fi Proxy"
        case .cert: return "CA Certificate"
        case .thirdPartyClient: return "Choose Client"
        case .thirdPartyImport: return "Import and Test"
        }
    }
}

struct FirstSetupView: View {
    @ObservedObject var setup: SetupCoordinator
    let onComplete: () -> Void

    @State private var step: SetupStep
    @State private var downloadedDone = false
    @State private var installedDone = false
    @State private var trustedDone = false
    @State private var result: VerificationResult?
    @State private var isVerifying = false
    @State private var isPreparingMode = false
    @State private var manualHint = ""
    @State private var setupActionError = ""
    @State private var showDiagnostics = false
    @StateObject private var diagnosticActions = LocationActionCoordinator()
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject private var motionSimulation = MotionSimulationStore.shared
    @State private var copiedSubscriptionURL = false
    @State private var copiedMITMHostname = false
    @State private var screenshotPreview: SetupScreenshotPreview?
    @State private var certificateDownloadDestination: CertificateDownloadDestination?
    @State private var thirdPartyTestFailure: ThirdPartyConnectionTestFailure?
    @State private var showThirdPartyRepairReason: Bool
    @State private var showsVerificationResult: Bool
    @State private var showsThirdPartyFailureLog: Bool

    init(setup: SetupCoordinator, onComplete: @escaping () -> Void) {
        self.setup = setup
        self.onComplete = onComplete
        _step = State(initialValue: setup.setupStep)
        _showThirdPartyRepairReason = State(
            initialValue: setup.setupStep == .thirdPartyImport && !setup.message.isEmpty
        )
        _showsVerificationResult = State(
            initialValue: [.proxy, .cert].contains(setup.setupStep)
                && setup.lastVerificationResult != nil
        )
        _showsThirdPartyFailureLog = State(
            initialValue: setup.setupStep == .thirdPartyImport && !setup.message.isEmpty
        )
    }

    private var certificateStepsComplete: Bool { downloadedDone && installedDone && trustedDone }
    private var diagnosticFavorite: FavoriteLocation {
        FavoriteLocation(name: "Diagnostic Location", latitude: 22.544577, longitude: 113.94114, accuracy: 25)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                progress
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch step {
                            case .mode: modeStep
                            case .proxy: proxyStep
                            case .cert: certificateStep
                            case .thirdPartyClient: thirdPartyClientStep
                            case .thirdPartyImport: thirdPartyImportStep
                            }
                            if let displayedVerificationResult { resultView(displayedVerificationResult) }
                        }
                        .padding(20)
                    }
                    .onChange(of: thirdPartyFailureLog) { failureLog in
                        guard step == .thirdPartyImport, failureLog != nil else { return }
                        DispatchQueue.main.async {
                            withAnimation {
                                scrollProxy.scrollTo("thirdPartyFailureLog", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: step) { _ in
                        showsVerificationResult = false
                        showsThirdPartyFailureLog = false
                    }
                }
                Divider()
                if step != .mode {
                    HStack(spacing: 12) {
                        Button {
                            returnToPreviousStep()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isVerifying || thirdPartyProxy.isRequesting)
                        Spacer(minLength: 12)
                        primaryAction
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Get Started")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDiagnostics) {
                NavigationView {
                    RuntimeLogsView(
                        setup: setup,
                        actions: diagnosticActions,
                        testFavorite: diagnosticFavorite
                    )
                }
            }
            .sheet(item: $screenshotPreview) { preview in
                NavigationView {
                    ScrollView {
                        Image(uiImage: preview.image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding()
                    }
                    .navigationTitle(preview.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { screenshotPreview = nil }
                        }
                    }
                }
            }
            .sheet(item: $certificateDownloadDestination) { destination in
                SafariView(url: destination.url)
                    .ignoresSafeArea()
            }
            .alert("Unable to Open Settings", isPresented: Binding(
                get: { !manualHint.isEmpty },
                set: { if !$0 { manualHint = "" } }
            )) {
                Button("Got It", role: .cancel) {}
            } message: { Text(manualHint) }
            .alert("Action Failed", isPresented: Binding(
                get: { !setupActionError.isEmpty },
                set: { if !$0 { setupActionError = "" } }
            )) {
                Button("View Diagnostic Logs") { showDiagnostics = true }
                Button("Got It", role: .cancel) {}
            } message: {
                Text(setupActionError)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(visibleSteps, id: \.rawValue) { value in
                HStack(spacing: 6) {
                    Circle()
                        .fill(value.rawValue <= step.rawValue ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(value.title).font(.caption).foregroundStyle(.secondary)
                }
                if value != visibleSteps.last {
                    Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 28, height: 2)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var visibleSteps: [SetupStep] {
        switch step {
        case .mode:
            return [.mode]
        case .proxy, .cert:
            return [.mode, .proxy, .cert]
        case .thirdPartyClient, .thirdPartyImport:
            return [.mode, .thirdPartyClient, .thirdPartyImport]
        }
    }

    private var displayedVerificationResult: VerificationResult? {
        guard showsVerificationResult else { return nil }
        return result ?? setup.lastVerificationResult
    }

    private var thirdPartyFailureLog: String? {
        guard showsThirdPartyFailureLog else { return nil }
        if let thirdPartyTestFailure {
            return thirdPartyTestFailure.message
        }
        guard !setup.message.isEmpty else { return nil }
        return """
        ======== Third-Party Proxy Runtime Test ========
        Current client: \(thirdPartyClient.selectedClient.name)
        Triggered by: A third-party proxy action from the map or Settings
        Request: WLOC configuration endpoint
        Result: Failed
        Details: \(setup.message)
        Suggested fix: Confirm the module is enabled, then check MITM, the certificate, and the proxy/VPN connection.
        """
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Runtime Mode")
                .font(.title2.bold())
            Text("You can change this later under Settings → Runtime Mode. Do not let both modes intercept WLOC requests at the same time.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            modeCard(
                title: "App Mode",
                icon: "iphone.and.arrow.forward",
                badges: ["Wi-Fi Only", "No External Client"],
                description: "Location Spoofer runs a local proxy on this iPhone and uses the connected Wi-Fi network's manual HTTP proxy setting to modify location responses. A self-signed app cannot use the Network Extension required for a system VPN, so App Mode does not work over cellular data. It requires the manual Wi-Fi proxy and the CA certificate generated by this app.",
                tint: .blue
            ) {
                selectMode(.localWiFi)
            }
            .disabled(isPreparingMode)

            modeCard(
                title: "Third-Party Proxy Mode",
                icon: "network.badge.shield.half.filled",
                badges: ["Wi-Fi + 4G/5G", "Experimental"],
                description: "Location Spoofer selects the location and uses the WLOC configuration endpoint to read and synchronize coordinates. A third-party proxy client handles traffic routing, module interception, MITM, and persistent storage, including its own certificate and VPN connection.",
                tint: .orange
            ) {
                selectMode(.thirdParty)
            }
            .disabled(isPreparingMode)

            if isPreparingMode {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing App Mode's local services…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func modeCard(
        title: String,
        icon: String,
        badges: [String],
        description: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    private var proxyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(label: Label("Configure the Wi-Fi Proxy First", systemImage: "wifi")) {
                Text("Open the details for your connected Wi-Fi network. Under Configure Proxy, choose Manual, enter 127.0.0.1 as the server and 8888 as the port, then return here and tap Continue. The connection test will distinguish between an incorrect proxy setting and an untrusted certificate.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            setupScreenshot(
                assetName: "AppModeWiFiProxy",
                title: "Wi-Fi Proxy Settings",
                caption: "1 Choose Manual. 2 Enter 127.0.0.1 as the server. 3 Enter 8888 as the port."
            )
            HStack(spacing: 12) {
                Button { UIPasteboard.general.string = "127.0.0.1:8888" } label: {
                    Label("Copy Address", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { openSettings(.wifi) } label: {
                    Label("Open Wi-Fi Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var certificateStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            certificateCard(
                title: "Step 1: Download the Certificate",
                icon: "arrow.down.circle",
                description: "Download the CA root certificate generated specifically for this device. Its private key remains in this iPhone's Keychain and is never included in the downloaded certificate file. Safari will open a download page; when iOS asks to allow a configuration profile download, tap Allow.",
                actionTitle: "Open Download Page",
                actionIcon: "arrow.down.circle.fill",
                complete: downloadedDone,
                action: {
                    Task {
                        if let url = await setup.proxy.prepareCertificateDownloadURL() {
                            certificateDownloadDestination = CertificateDownloadDestination(url: url)
                        } else {
                            setupActionError = setup.proxy.error ?? "The certificate download page could not be prepared. Check the diagnostic logs for details."
                        }
                    }
                },
                markComplete: { downloadedDone = true }
            )
            certificateCard(
                title: "Step 2: Install the Certificate",
                icon: "square.and.arrow.down",
                description: "After the download finishes, open the Settings app. If Profile Downloaded appears near the top, tap it and install the profile. Otherwise go to General → VPN & Device Management, select Location Spoofer CA, and install it.",
                actionTitle: "Open Settings",
                actionIcon: "gearshape",
                complete: installedDone,
                action: { openSettings(.general) },
                markComplete: { installedDone = true }
            )
            setupScreenshot(
                assetName: "AppModeCertificateInstall",
                title: "Install the Certificate",
                caption: "1 Under VPN & Device Management, open the Location Spoofer CA profile and complete the installation."
            )
            certificateCard(
                title: "Step 3: Trust the Certificate",
                icon: "shield.checkered",
                description: "After installation, go to Settings → General → About → Certificate Trust Settings. Find Location Spoofer CA and enable full trust. If iOS keeps the app's Keychain data, reinstalling the app will continue to use the same certificate.",
                actionTitle: "Open Trust Settings",
                actionIcon: "shield.checkered",
                complete: trustedDone,
                action: { openSettings(.general) },
                markComplete: { trustedDone = true }
            )
            setupScreenshot(
                assetName: "AppModeCertificateTrust",
                title: "Trust the Certificate",
                caption: "1 Under Certificate Trust Settings, enable full trust for Location Spoofer CA."
            )
        }
    }

    private var thirdPartyClientStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            GroupBox(label: Label("Choose a Third-Party Proxy Client", systemImage: "app.badge.checkmark")) {
                VStack(spacing: 0) {
                    ForEach(ThirdPartyProxyClient.allCases) { client in
                        Button {
                            thirdPartyClient.select(client)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(client.name).foregroundStyle(.primary)
                                    if let verificationText = client.verificationText {
                                        Text(verificationText)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: thirdPartyClient.selectedClient == client ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(thirdPartyClient.selectedClient == client ? .blue : .secondary)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if client != ThirdPartyProxyClient.allCases.last { Divider() }
                    }
                }
            }

            Text("Only the Shadowrocket setup has been tested on a physical device. For other clients, this page provides the module import link and general configuration guidance only.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            DisclosureGroup("Third-Party Client Integration Notes") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How It Works")
                        .font(.subheadline.bold())
                    Text("The app does not send coordinates to a remote server. Instead, it makes a defined request to an Apple hostname. The third-party client must intercept that request locally, store the WGS-84 coordinates, and return JSON. The location module then reads the same stored data and modifies the Apple WLOC response.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Configuration Endpoint")
                        .font(.subheadline.bold())
                    Text(ThirdPartyProxyManager.configurationEndpoint.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("""
                    Query: GET ?action=query
                    Save: GET ?lon=<longitude>&lat=<latitude>&acc=<accuracy>
                    Clear: GET ?action=clear
                    """)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("Response Format")
                        .font(.subheadline.bold())
                    Text("""
                    Success: {"success":true,"longitude":113.0,"latitude":22.0,"accuracy":25}
                    Failure: {"success":false,"error":"Error description"}
                    """)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("Integration Requirements")
                        .font(.subheadline.bold())
                    Text("The client must support request scripts, persistent storage, HTTP 200 JSON responses, response scripting for Apple WLOC traffic, and HTTPS decryption for gs-loc.apple.com and gs-loc-cn.apple.com. The save endpoint and WLOC response script must use the same persistent data store.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private var thirdPartyImportStep: some View {
        let client = thirdPartyClient.selectedClient
        return VStack(alignment: .leading, spacing: 16) {
            if showThirdPartyRepairReason {
                Label(
                    "The third-party proxy connection failed. Check the module, MITM settings, and proxy connection, then run the test again.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("Step 1: Import the \(client.name) Module", systemImage: "square.and.arrow.down")) {
                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(1, "Copy the module subscription URL for \(client.name).")
                    Button {
                        UIPasteboard.general.string = client.subscriptionURL.absoluteString
                        copiedSubscriptionURL = true
                    } label: {
                        Label(copiedSubscriptionURL ? "Module URL Copied" : "Copy Module URL", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    instructionRow(2, client == .shadowrocket
                        ? "Open Shadowrocket and go to Config → Modules."
                        : "Open \(client.name).")
                    Button {
                        openThirdPartyClient(client)
                    } label: {
                        Label("Open \(client.name)", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if client == .shadowrocket {
                        setupScreenshot(
                            assetName: "ShadowrocketConfigDetails",
                            title: "Open Shadowrocket Configuration",
                            caption: "1 Tap Modules to open the module list. 2 You can also open the details of the current local configuration."
                        )
                    }

                    if client == .shadowrocket {
                        instructionRow(3, "Tap + in the top-right corner, paste the module subscription URL, import it, and confirm that the module is enabled.")
                        setupScreenshot(
                            assetName: "ShadowrocketModuleImport",
                            title: "Import the Shadowrocket Module",
                            caption: "1 Tap + in the top-right corner to import the module. 2 Confirm that the module is enabled."
                        )
                    } else {
                        instructionRow(3, "In \(client.name), import the module subscription URL you just copied.")
                    }
                }
            }

            if client == .shadowrocket {
                shadowrocketHTTPSDecryptionGuide
            } else {
                GroupBox(label: Label("Step 2: Finish Configuring \(client.name)", systemImage: "slider.horizontal.3")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Complete the required configuration in \(client.name).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Use both gs-loc.apple.com and gs-loc-cn.apple.com as the HTTPS decryption hostnames.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        mitmHostnameCopyButton
                    }
                }
            }

            if let thirdPartyFailureLog {
                testResultView(
                    success: false,
                    title: "Endpoint Connection Failed",
                    log: thirdPartyFailureLog
                )
                .id("thirdPartyFailureLog")
            }
        }
    }

    private var shadowrocketHTTPSDecryptionGuide: some View {
        GroupBox(label: Label("Step 2: Configure HTTPS Decryption", systemImage: "lock.open")) {
            VStack(alignment: .leading, spacing: 12) {
                instructionRow(1, "Go to Config → Local Files, find the configuration marked with a yellow dot, and tap the info button on its right.")
                instructionRow(2, "Open HTTPS Decryption and turn it on.")
                instructionRow(3, "Add gs-loc.apple.com and gs-loc-cn.apple.com to the hostname list.")
                setupScreenshot(
                    assetName: "ShadowrocketHTTPSDecryption",
                    title: "Configure HTTPS Decryption",
                    caption: "1 Enable HTTPS Decryption. 2 Add gs-loc.apple.com and gs-loc-cn.apple.com. 3 Open the certificate settings."
                )

                mitmHostnameCopyButton

                instructionRow(4, "Follow Shadowrocket's prompts to generate, install, and trust its certificate.")
                setupScreenshot(
                    assetName: "ShadowrocketHTTPSCA",
                    title: "Trust the Shadowrocket Certificate",
                    caption: "1 Open Shadowrocket's certificate settings, then follow the prompts to install and trust the certificate."
                )
                instructionRow(5, "Return to the HTTPS Decryption page, tap the checkmark in the top-right corner to save, then connect the proxy.")

                Button {
                    openThirdPartyClient(.shadowrocket)
                } label: {
                    Label("Open Shadowrocket to Continue", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("The app can open Shadowrocket, but Shadowrocket does not provide a public link that opens the Modules or HTTPS Decryption page directly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mitmHostnameCopyButton: some View {
        Button {
            UIPasteboard.general.string = ThirdPartyProxyManager.interceptionHostnamesText
            copiedMITMHostname = true
        } label: {
            Label(
                copiedMITMHostname ? "Hostnames Copied" : "Copy Both Hostnames",
                systemImage: "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func setupScreenshot(
        assetName: String,
        title: String,
        caption: String
    ) -> some View {
        if let image = UIImage(named: assetName) {
            Button {
                screenshotPreview = SetupScreenshotPreview(
                    image: image,
                    title: title
                )
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text(caption)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)：\(caption)")
            .accessibilityHint("Tap to view the full-size image")
        }
    }

    private func openThirdPartyClient(_ client: ThirdPartyProxyClient) {
        guard let url = client.launchURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                manualHint = "Unable to open \(client.name). Confirm that it is installed, then open it manually."
            }
        }
    }

    private func returnToPreviousStep() {
        result = nil
        setupActionError = ""
        switch step {
        case .mode:
            break
        case .proxy, .thirdPartyClient:
            step = .mode
        case .cert:
            step = .proxy
        case .thirdPartyImport:
            thirdPartyTestFailure = nil
            step = .thirdPartyClient
        }
    }

    private func certificateCard(
        title: String,
        icon: String,
        description: String,
        actionTitle: String,
        actionIcon: String,
        complete: Bool,
        action: @escaping () -> Void,
        markComplete: @escaping () -> Void
    ) -> some View {
        GroupBox(label: Label(title, systemImage: icon)) {
            VStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 0).padding(.top, 2)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionIcon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    Button(action: markComplete) {
                        Label(
                            complete ? "Completed ✓" : "Mark Complete",
                            systemImage: complete ? "checkmark.circle.fill" : "circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(complete ? .green : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: VerificationResult) -> some View {
        let success = result.isSuccess
        testResultView(
            success: success,
            title: success ? "Environment Check Passed" : failureSummary(result),
            log: setup.testLog
        )
    }

    private func testResultView(success: Bool, title: String, log: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.subheadline.weight(.semibold))
            if !success {
                Text(log).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
                Button {
                    showDiagnostics = true
                } label: {
                    Label("View Diagnostic Logs", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background((success ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if step == .mode {
            EmptyView()
        } else if step == .proxy {
            Button {
                verifyAfterProxyConfirmation()
            } label: {
                actionLabel("Continue")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying)
        } else if step == .cert {
            Button {
                verifyAfterCertificateConfirmation()
            } label: {
                actionLabel("Continue")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!certificateStepsComplete || isVerifying)
        } else if step == .thirdPartyClient {
            Button {
                step = .thirdPartyImport
            } label: {
                actionLabel("Continue")
            }
                .buttonStyle(.borderedProminent)
        } else {
            Button {
                verifyThirdPartyConnection()
            } label: {
                actionLabel("Run Connection Test")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || thirdPartyProxy.isRequesting)
        }
    }

    private func selectMode(_ mode: ProxyRuntimeMode) {
        guard !isPreparingMode else { return }
        runtimeMode.setMode(mode)
        result = nil
        switch mode {
        case .localWiFi:
            isPreparingMode = true
            Task { @MainActor in
                await setup.prepareLocalServices()
                isPreparingMode = false
                step = .proxy
            }
        case .thirdParty:
            setup.proxy.stop()
            BackgroundKeepAlive.shared.stop()
            step = .thirdPartyClient
        }
    }

    private func verifyThirdPartyConnection() {
        guard !isVerifying else { return }
        let client = thirdPartyClient.selectedClient
        let startedAt = Date()
        isVerifying = true
        result = nil
        thirdPartyTestFailure = nil
        showsThirdPartyFailureLog = false
        setup.message = ""
        RuntimeLogger.info("APP", "ThirdPartyProxy", "Started third-party proxy connection test", details: [
            "Client": client.name,
            "Request": "WLOC query",
            "Checks": "Module interception, MITM, proxy/VPN connection"
        ])
        Task { @MainActor in
            defer { isVerifying = false }
            do {
                let response = try await thirdPartyProxy.validateConnection()
                let advancedFeaturesAvailable = await thirdPartyProxy.refreshAdvancedFeatureAvailability()
                if !advancedFeaturesAvailable {
                    motionSimulation.setEnabled(false)
                }
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                RuntimeLogger.info("APP", "ThirdPartyProxy", "Third-party proxy connection test passed", details: [
                    "Client": client.name,
                    "Request": "WLOC query",
                    "Connection": response.latitude == nil || response.longitude == nil ? "Connected; no saved coordinates" : "Connected; saved coordinates found",
                    "Motion simulation": advancedFeaturesAvailable ? "Supported" : "Unsupported; disabled",
                    "Elapsed milliseconds": String(elapsedMilliseconds)
                ])
                onComplete()
            } catch {
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                let connectionState = thirdPartyConnectionStateDescription
                let errorType = String(describing: type(of: error))
                RuntimeLogger.error(
                    "APP",
                    "ThirdPartyProxy",
                    "Third-party proxy connection test failed",
                    error: error,
                    details: [
                        "Client": client.name,
                        "Request": "WLOC query",
                        "Connection": connectionState,
                        "Elapsed milliseconds": String(elapsedMilliseconds),
                        "Error type": errorType,
                        "Suggested fix": ThirdPartyProxyError.recoverySuggestion(for: error)
                    ]
                )
                thirdPartyTestFailure = ThirdPartyConnectionTestFailure(
                    message: """
                    ======== Third-Party Proxy Connection Test ========
                    Client: \(client.name)
                    Configuration endpoint: /wloc-settings/save
                    Request: WLOC query
                    Checks: Module interception, MITM, certificate, and proxy/VPN connection
                    Connection: \(connectionState)
                    Result: Failed
                    Elapsed time: \(elapsedMilliseconds) ms
                    Error type: \(errorType)
                    Details: \(error.localizedDescription)
                    Suggested fix: \(ThirdPartyProxyError.recoverySuggestion(for: error)).
                    """
                )
                showsThirdPartyFailureLog = true
            }
        }
    }

    private var thirdPartyConnectionStateDescription: String {
        switch thirdPartyProxy.connectionState {
        case .unknown:
            return "Not tested"
        case .connected(let active):
            return active ? "Connected; saved coordinates found" : "Connected; no saved coordinates"
        case .failed(let message):
            return "Connection failed (\(message))"
        }
    }

    private func actionLabel(_ title: String) -> some View {
        HStack {
            if isVerifying { ProgressView().tint(.white).controlSize(.small) }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }

    private func verifyAfterProxyConfirmation() {
        runVerification { result in
            if result.isSuccess {
                onComplete()
            } else if result == .certNotTrusted {
                step = .cert
            } else {
                step = .proxy
            }
        }
    }

    private func verifyAfterCertificateConfirmation() {
        runVerification { result in
            if result.isSuccess {
                onComplete()
            } else if result != .certNotTrusted {
                step = .proxy
            }
        }
    }

    private func runVerification(completion: @escaping (VerificationResult) -> Void) {
        guard !isVerifying else { return }
        isVerifying = true
        result = nil
        showsVerificationResult = false
        Task {
            let verification = await setup.runVerificationTest()
            setup.applyVerificationResult(verification)
            guard !Task.isCancelled else { return }
            result = verification
            showsVerificationResult = true
            isVerifying = false
            completion(verification)
        }
    }

    private func failureSummary(_ result: VerificationResult) -> String {
        switch result {
        case .certNotTrusted: return "The certificate is not installed or trusted"
        case .wifiProxyNotConfigured: return "The Wi-Fi proxy is not configured correctly"
        case .proxyNotRunning: return "The local proxy could not start"
        case .verificationInProgress: return "The check is still running"
        case .verificationSuperseded: return "This check result is no longer current"
        case .coordinateWriteFailed: return "The coordinates could not be saved"
        case .patchFailed: return "The location modification test failed"
        case .success: return "Environment check passed"
        }
    }

    @MainActor
    private func openSettings(_ destination: SystemSettingsDestination) {
        SystemSettingsNavigator.open(destination) { fallbackHint in
            if let fallbackHint { manualHint = fallbackHint }
        }
    }
}
