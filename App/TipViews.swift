import SwiftUI

enum TipKind: String, Identifiable {
    case activation = "Activation Guide"
    case deactivation = "Restoration Guide"
    case removeProxy = "Disable Wi-Fi Proxy"
    var id: String { rawValue }
}

struct TipSheetView: View {
    let kind: TipKind
    var runtimeMode: ProxyRuntimeMode = .localWiFi
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch kind {
                    case .activation: ActivationTipContent(runtimeMode: runtimeMode, dismiss: { dismiss() })
                    case .deactivation: DeactivationTipContent(runtimeMode: runtimeMode, dismiss: { dismiss() })
                    case .removeProxy: RemoveProxyTipContent(dismiss: { dismiss() })
                    }
                }.padding(16)
            }
            .navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("Got It").font(.body.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(.blue).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

@MainActor
private func openSettings(_ destination: SystemSettingsDestination) {
    guard let appSettingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    // Try the preferred (private) URL scheme first; fall back to reliable app-settings:
    if let preferredURL = destination.preferredURL, preferredURL != appSettingsURL {
        UIApplication.shared.open(preferredURL) { opened in
            if !opened {
                UIApplication.shared.open(appSettingsURL)
            }
        }
    } else {
        UIApplication.shared.open(appSettingsURL)
    }
}

// MARK: - Activation guide

struct ActivationTipContent: View {
    var runtimeMode: ProxyRuntimeMode = .localWiFi
    let dismiss: () -> Void

    var body: some View {
        GroupBox(label: Label("Apply the Virtual Location", systemImage: "checklist")) {
            VStack(alignment: .leading, spacing: 10) {
                if runtimeMode == .thirdParty {
                    step(0, "Confirm the Proxy Is Running", "Keep the imported WLOC module, HTTPS decryption, and the third-party proxy/VPN connection enabled.")
                }
                step(1, "Turn On Airplane Mode", "Open Control Center and tap the airplane icon. Wi-Fi should disconnect automatically. This begins clearing iOS's cached location. Wait 2 seconds.")
                step(2, "Make Sure Wi-Fi Is Off", "In Control Center, confirm that Wi-Fi is disconnected. Wait 2 seconds.")
                systemStep(3, "Turn Off Location Services", "Open Settings → Privacy & Security → Location Services and turn off the main switch. Wait 2 seconds.")
                step(4, "Reconnect Wi-Fi", runtimeMode == .thirdParty ? "Keep Airplane Mode on, turn Wi-Fi back on, and confirm the third-party proxy reconnects. The coordinates are already synchronized. Wait 2 seconds." : "Keep Airplane Mode on and turn Wi-Fi back on. Return to Location Spoofer and confirm the virtual location is still enabled. Wait 2 seconds.")
                step(5, "Turn Off Airplane Mode", "Turn off Airplane Mode from Control Center. Wait 2 seconds.")
                systemStep(6, "Turn Location Services Back On", "Return to Settings → Privacy & Security → Location Services and enable the main switch. Then open Maps to verify the new location.")
            }.padding(.vertical, 4)
        }

        GroupBox(label: Label("Still Showing the Old Location?", systemImage: "exclamationmark.triangle")) {
            Text("Repeat the procedure through step 3, restart the iPhone while Location Services is off, and continue from step 4 after it starts. This performs a more thorough cache reset.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }

    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.15), in: Circle()).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func systemStep(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.18), in: Circle()).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { openSettings(.locationServices) } label: {
                    Label("Open Settings", systemImage: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).tint(.blue)
            }
        }
    }
}

// MARK: - Restoration guide

struct DeactivationTipContent: View {
    var runtimeMode: ProxyRuntimeMode = .localWiFi
    let dismiss: () -> Void

    var body: some View {
        GroupBox(label: Label("Restore the Real Location", systemImage: "arrow.uturn.backward.circle")) {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Turn On Airplane Mode", "Open Control Center and turn on Airplane Mode. Wi-Fi should disconnect automatically. Wait 2 seconds.")
                step(2, "Make Sure Wi-Fi Is Off", "Confirm in Control Center that Wi-Fi is disconnected. Wait 2 seconds.")
                systemStep(3, "Turn Off Location Services", "Open Settings → Privacy & Security → Location Services and turn off the main switch. Wait 2 seconds.")
                if runtimeMode == .thirdParty {
                    step(4, "Confirm the Coordinates Were Cleared", "Location Spoofer has asked the third-party proxy to remove the virtual coordinates. Keep the network available and wait 2 seconds.")
                } else {
                    systemStep(4, "Reconnect Wi-Fi and Remove the Proxy", "Turn Wi-Fi back on. Then open Settings → Wi-Fi → tap the (i) beside the connected network → Configure Proxy, choose Off, and save. Wait 2 seconds.")
                }
                step(5, "Turn Off Airplane Mode", "Turn off Airplane Mode from Control Center. Wait 2 seconds.")
                systemStep(6, "Turn Location Services Back On", "Return to Settings → Privacy & Security → Location Services and enable the main switch. Open Maps and verify that your real location has returned.")
            }.padding(.vertical, 4)
        }

        GroupBox(label: Label("Still Showing the Virtual Location?", systemImage: "exclamationmark.triangle")) {
            Text("Repeat the procedure through step 3, restart the iPhone while Location Services is off, and continue from step 4 after it starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }

    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.15), in: Circle()).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func systemStep(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.18), in: Circle()).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { openSettings(.locationServices) } label: {
                    Label("Open Settings", systemImage: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).tint(.blue)
            }
        }
    }
}

// MARK: - Remove Wi-Fi proxy

struct RemoveProxyTipContent: View {
    let dismiss: () -> Void

    var body: some View {
        GroupBox(label: Label("Remove the Wi-Fi Proxy", systemImage: "wifi.slash")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("After stopping the virtual location, remove the manual Wi-Fi proxy or your internet connection may stop working.\n\n1. Open Settings → Wi-Fi\n2. Tap the (i) beside the connected network\n3. Open Configure Proxy\n4. Select Off\n5. Tap Save")
                    .font(.caption).foregroundStyle(.primary)
                Button { openSettings(.wifi) } label: {
                    Label("Open Settings", systemImage: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).tint(.blue)
            }.padding(.vertical, 4)
        }
    }
}
