import SwiftUI

struct BugReportView: View {
    @ObservedObject var setup: SetupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var isReproducible = true
    @State private var isRunning = false
    @State private var showCopiedAlert = false
    @State private var githubDestination: SafariDestination?
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 说明
                    Text("If you encounter a problem, generate a bug report here. The app will run a diagnostic test and copy the complete report to the clipboard. After GitHub opens, paste it into the App-Generated Diagnostic Report field.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // 可复现环境
                    Toggle(isOn: $isReproducible) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Consistently Reproducible").font(.subheadline.weight(.medium))
                            Text("The problem occurs consistently on this device rather than intermittently.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 问题描述
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Problem Description").font(.subheadline.weight(.medium))
                        TextEditor(text: $description)
                            .font(.caption)
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            }

            Divider()
            // 底部按钮
            VStack(spacing: 8) {
                Button {
                    generateReport()
                } label: {
                    HStack {
                        if isRunning {
                            ProgressView().tint(.white)
                        }
                        Text(isRunning ? "Generating Report…" : "Generate Bug Report")
                            .font(.body.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isRunning || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .navigationTitle("Report a Bug")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Report Generated", isPresented: $showCopiedAlert) {
            Button("Open GitHub Form") {
                githubDestination = SafariDestination(url: GitHubSubmission.bugReportURL)
            }
            Button("Later", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("The bug report has been copied to the clipboard. Paste it into the App-Generated Diagnostic Report field in the GitHub form, then submit it.")
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
    }

    private func generateReport() {
        isRunning = true
        Task {
            let testLog: String
            if runtimeMode.mode == .thirdParty {
                do {
                    let response = try await thirdPartyProxy.query()
                    let active = response.success && response.latitude != nil && response.longitude != nil
                    testLog = "Third-Party Proxy Mode: module connection succeeded; saved coordinates = \(active ? "yes" : "no")"
                } catch {
                    testLog = "Third-Party Proxy Mode: module connection failed; \(error.localizedDescription)"
                }
            } else {
                _ = await setup.runVerificationTest()
                testLog = setup.testLog
            }

            // 获取版本信息
            let appVersion: String = {
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                return "\(v) (\(b))"
            }()
            let systemVersion = UIDevice.current.systemVersion

            // 拼接报告
            let report = """
            ### Environment
            App version: \(appVersion)
            System version: iOS \(systemVersion)
            Runtime mode: \(runtimeMode.mode.displayName)
            Third-party client: \(runtimeMode.mode == .thirdParty ? thirdPartyClient.selectedClient.name : "Not applicable")
            Consistently reproducible: \(isReproducible ? "Yes" : "No")

            ### Problem Description
            \(description.trimmingCharacters(in: .whitespacesAndNewlines))

            ### Diagnostic Logs
            ```
            \(testLog.isEmpty ? "(No diagnostic data)" : testLog)
            ```
            """

            // 复制到剪切板
            UIPasteboard.general.string = report
            isRunning = false

            // 弹窗
            showCopiedAlert = true
        }
    }
}
