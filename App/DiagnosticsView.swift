import SwiftUI
import UIKit

struct RuntimeLogsView: View {
    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var actions: LocationActionCoordinator
    let testFavorite: FavoriteLocation
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @State private var entries: [RuntimeLogEntry] = []
    @State private var isTesting = false
    @State private var testResult = ""
    @State private var testMessage = ""
    @State private var showClearConfirm = false
    @State private var copiedEntryID: UUID?
    @State private var copyLogsConfirmed = false
    @State private var testLogCopied = false
    @State private var logFilter = ""

    private var filteredEntries: [RuntimeLogEntry] {
        let q = logFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.message.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            testPanel
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter logs", text: $logFilter)
                    .textFieldStyle(.plain).font(.caption)
                if !logFilter.isEmpty {
                    Button { logFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text(entries.isEmpty ? "No runtime logs" : "No matching logs").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredEntries.reversed()) { entry in logRow(entry) }
                    }.padding(12)
                }
            }
        }
        .navigationTitle("Runtime Logs").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("Logs are removed automatically after 3 days")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = entries.map(\.renderedText).joined(separator: "\n")
                    copyLogsConfirmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyLogsConfirmed = false }
                } label: {
                    Image(systemName: copyLogsConfirmed ? "checkmark" : "doc.on.doc")
                }
                .disabled(entries.isEmpty)
                .accessibilityLabel("Copy all logs")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(entries.isEmpty)
                .accessibilityLabel("Clear all logs")
            }
        }
        .confirmationDialog("Clear All Runtime Logs?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Logs", role: .destructive) {
                RuntimeLogStore.clearAll()
                entries = []
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            while !Task.isCancelled { refresh(); try? await Task.sleep(nanoseconds: 750_000_000) }
        }
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isTesting = true; testResult = ""; testLogCopied = false
                Task {
                    if runtimeMode.mode == .thirdParty {
                        await runThirdPartyConnectionTest()
                    } else {
                        let result = await setup.runVerificationTest()
                        testResult = result.isSuccess ? "Environment check passed" : "Environment check failed: \(result.id)"
                        if !result.isSuccess { testResult += "; see the logs below" }
                        testMessage = setup.testLog
                    }
                    isTesting = false; refresh()
                }
            } label: {
                HStack(spacing: 8) {
                    if isTesting {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                    }
                    Text(isTesting ? "Testing…" : "Run Environment Check").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).opacity(0.5)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isTesting ? Color.gray : Color.blue)
            )
            .disabled(isTesting || actions.state.isBusy)
            Text(runtimeMode.mode == .thirdParty
                 ? "Checks whether the third-party module intercepts and responds to a query request. It does not write test coordinates."
                 : "Checks the local proxy, CA certificate trust, and Wi-Fi proxy connection in sequence.")
                .font(.caption).foregroundStyle(.secondary)
            if !testMessage.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Test Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = testMessage
                            testLogCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { testLogCopied = false }
                        } label: {
                            HStack(spacing: 4) {
                                if testLogCopied {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    Text("Copied").font(.system(size: 11))
                                } else {
                                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                                }
                            }
                            .foregroundStyle(testLogCopied ? .green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(testLogCopied ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { testMessage = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView {
                        Text(testMessage)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }.frame(maxHeight: 180)
                }
            }
            if runtimeMode.mode == .localWiFi {
                HStack(spacing: 14) {
                    Label(proxy.isRunning ? "Proxy Running" : "Proxy Stopped", systemImage: proxy.isRunning ? "play.circle" : "stop.circle")
                    Label(setup.canModify ? "Modification Available" : "Modification Unavailable", systemImage: setup.canModify ? "checkmark.shield.fill" : "xmark.shield")
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !testResult.isEmpty {
                Text(testResult).font(.footnote.weight(.medium))
                    .foregroundStyle(testResult.contains("passed") ? .green : .red)
            }
        }.padding(14).background(Color(.secondarySystemBackground))
    }

    private func logRow(_ entry: RuntimeLogEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry.level == .error ? "xmark.octagon.fill" : entry.level == .warning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .blue).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(entry.source) \(entry.category)").font(.caption.weight(.semibold))
                    Spacer()
                    Button {
                        UIPasteboard.general.string = entry.renderedText
                        copiedEntryID = entry.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedEntryID == entry.id { copiedEntryID = nil }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if copiedEntryID == entry.id {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                Text("Copied").font(.system(size: 11))
                            } else {
                                Image(systemName: "doc.on.doc").font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(copiedEntryID == entry.id ? .green : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(copiedEntryID == entry.id ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Text(entry.message).font(.caption.monospaced()).textSelection(.enabled)
                if !entry.details.isEmpty {
                    Text(entry.details.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refresh() { entries = RuntimeLogStore.loadAll() }

    @MainActor
    private func runThirdPartyConnectionTest() async {
        do {
            let response = try await thirdPartyProxy.query()
            let active = response.success && response.latitude != nil && response.longitude != nil
            testResult = active ? "Third-party module connected; coordinates are saved" : "Third-party module connected; no coordinates are saved"
            testMessage = """
            ======== Third-Party Proxy Connection Test ========
            Mode: Third-Party Proxy Mode
            Request: wloc-settings/save?action=query
            Intercepted response: Valid JSON
            Saved coordinates: \(active ? "Yes" : "No")
            """
        } catch {
            testResult = "Third-party module connection failed"
            testMessage = """
            ======== Third-Party Proxy Connection Test ========
            Mode: Third-Party Proxy Mode
            Request: wloc-settings/save?action=query
            Result: \(error.localizedDescription)
            """
        }
    }
}
