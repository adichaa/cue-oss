import SwiftUI

private let errorRed      = Color(red: 0.98, green: 0.40, blue: 0.44)
private let settingsAmber = Color(red: 0.96, green: 0.74, blue: 0.32)
private let settingsIndigo = Color(red: 0.42, green: 0.42, blue: 0.90)

struct SettingsView: View {
    @ObservedObject var settings: Settings

    enum TestStatus: Equatable {
        case idle, testing
        case ok(String)
        case failed(String)
    }

    @State private var connectionStatus: TestStatus = .idle
    @State private var howExpanded   = true
    @State private var modesExpanded = true
    @State private var setupExpanded = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                CollapsibleSection(title: "How to use", isExpanded: $howExpanded) {
                    howItWorksContent
                }
                CollapsibleSection(title: "Modes", isExpanded: $modesExpanded) {
                    modesContent
                }
                CollapsibleSection(title: "Setup", isExpanded: $setupExpanded) {
                    setupContent
                }
            }
            .padding(24)
        }
        .frame(width: 520)
        .frame(minHeight: 420, maxHeight: 680)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("cue")
                .font(.system(size: 18, weight: .semibold))
            Text("Ask anything. Run anything. Never leave your screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - How to use

    private var howItWorksContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                triggerRow(keys: ["q", "q"],           label: "Open cue",          detail: "Type anywhere — cue appears as an overlay")
                Divider().padding(.leading, 112)
                triggerRow(keys: ["q", "q", "q"],       label: "Voice input",       detail: "Speak your prompt instead of typing")
                Divider().padding(.leading, 112)
                triggerRow(keys: ["⌘", "⇧", "Space"],  label: "Fallback shortcut", detail: "Works without Accessibility permission")
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("Accessibility permission required for qq / qqq detection.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func triggerRow(keys: [String], label: String, detail: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                }
            }
            .frame(width: 88, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Modes

    private var modesContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                modeRow(
                    icon: "bolt.slash",
                    iconColor: .secondary,
                    label: "Coach",
                    detail: "Cue guides you step by step through anything on your screen — navigating software, filling forms, learning a new tool."
                )
                Divider().padding(.leading, 44)
                modeRow(
                    icon: "bolt.fill",
                    iconColor: settingsAmber,
                    label: "Autonomous",
                    detail: "Cue just does it — runs commands, navigates browsers, clicks buttons. You watch or walk away. Tap ⚡ to toggle."
                )
                Divider().padding(.leading, 44)
                modeRow(
                    icon: "moon.fill",
                    iconColor: settingsIndigo,
                    label: "Agent",
                    detail: "For complex tasks — research, bulk file ops, multi-step automation. Runs silently while you work; chip shows progress, notification when done. Tap 🌙 to toggle."
                )
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("Autonomous and Agent are mutually exclusive — enabling one disables the other.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func modeRow(icon: String, iconColor: Color, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)
                .padding(.leading, 12)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.trailing, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Setup

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Section {
                    LabeledContent("Endpoint") {
                        TextField("", text: $settings.endpoint, prompt: Text(Settings.defaultEndpoint))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API key") {
                        SecureField("", text: $settings.apiKey, prompt: Text("sk-ant-…"))
                            .textFieldStyle(.roundedBorder)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get a key at console.anthropic.com → API Keys. Stored in macOS Keychain, never sent elsewhere.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Any Anthropic-compatible endpoint works (e.g. OpenRouter, Bedrock proxy).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button("Test connection") { runTest() }
                    .disabled(connectionStatus == .testing || settings.apiKey.isEmpty)
                connectionStatusLabel
                Spacer()
            }
        }
    }

    // MARK: - Connection status

    @ViewBuilder
    private var connectionStatusLabel: some View {
        switch connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let reply):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text(reply)
                    .font(.caption).foregroundStyle(.green)
                    .lineLimit(1).truncationMode(.tail)
            }
        case .failed(let msg):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(errorRed)
                Text(msg)
                    .font(.caption).foregroundStyle(errorRed)
                    .lineLimit(2).truncationMode(.tail)
            }
        }
    }

    private func runTest() {
        connectionStatus = .testing
        let client = AnthropicClient(settings: settings)
        Task {
            do {
                let reply = try await client.ping()
                connectionStatus = .ok(reply)
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - CollapsibleSection

private struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
