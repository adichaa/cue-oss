import SwiftUI
import AppKit

// MARK: - Permission state

enum PermissionKind: CaseIterable {
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .accessibility:   "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    var detail: String {
        switch self {
        case .accessibility:   "Required for qq / qqq detection — type anywhere to open cue."
        case .screenRecording: "Lets cue see your screen so it can guide you through your task."
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility:   "accessibility"
        case .screenRecording: "rectangle.dashed"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
    }

    func request() {
        switch self {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Window controller

@MainActor
final class PermissionWalkthroughController {
    static let shared = PermissionWalkthroughController()
    private var window: NSWindow?

    private init() {}

    func showIfNeeded(onComplete: @escaping () -> Void) {
        let missing = PermissionKind.allCases.filter { !$0.isGranted }
        let needsKey = Settings.shared.apiKey.isEmpty
        guard !missing.isEmpty || needsKey else { onComplete(); return }

        let view = PermissionWalkthroughView(onComplete: { [weak self] in
            self?.dismiss()
            onComplete()
        })
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = ""
        win.styleMask = [.titled, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - View

private enum WalkthroughStep: Equatable {
    case permission(PermissionKind)
    case apiKey
}

struct PermissionWalkthroughView: View {
    let onComplete: () -> Void

    @State private var stepIndex = 0
    @State private var statuses: [PermissionKind: Bool] = [:]
    @State private var polling = false
    @State private var apiKey: String = ""
    @State private var apiKeyError = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var steps: [WalkthroughStep] {
        var s: [WalkthroughStep] = PermissionKind.allCases
            .filter { statuses[$0] != true }
            .map { .permission($0) }
        s.append(.apiKey)
        return s
    }

    private var allPermsGranted: Bool { PermissionKind.allCases.allSatisfy { statuses[$0] == true } }
    private var totalSteps: Int { PermissionKind.allCases.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.08)
            stepCard
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 420, height: 340)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { refreshStatuses() }
        .onReceive(timer) { _ in if polling { refreshStatuses() } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Let's get cue set up")
                .font(.system(size: 14, weight: .semibold))
            Text("Two permissions + your API key and you're good to go.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    // MARK: - Step card

    @ViewBuilder
    private var stepCard: some View {
        VStack(spacing: 12) {
            // Progress dots
            HStack(spacing: 7) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    let done = isDone(i)
                    Circle()
                        .fill(done ? Color.green : (i == stepIndex ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .frame(width: 7, height: 7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: done)
                }
            }

            if stepIndex < PermissionKind.allCases.count {
                let perm = PermissionKind.allCases[stepIndex]
                permissionCard(perm)
            } else {
                apiKeyCard
            }
        }
        .padding(.vertical, 20)
    }

    private func permissionCard(_ perm: PermissionKind) -> some View {
        VStack(spacing: 10) {
            Image(systemName: perm.systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(statuses[perm] == true ? .green : .accentColor)
                .animation(.spring(response: 0.3), value: statuses[perm])

            VStack(spacing: 4) {
                Text(perm.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(perm.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var apiKeyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(apiKeyError ? .red : .accentColor)

            VStack(spacing: 4) {
                Text("Anthropic API Key")
                    .font(.system(size: 15, weight: .semibold))
                Text("Get yours at console.anthropic.com — starts with sk-ant-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            SecureField("sk-ant-…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 32)
                .onChange(of: apiKey) { apiKeyError = false }

            if apiKeyError {
                Text("Please enter your API key to continue.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip for now") { onComplete() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if stepIndex < PermissionKind.allCases.count {
                let perm = PermissionKind.allCases[stepIndex]
                if statuses[perm] == true {
                    Button("Next →") {
                        withAnimation { stepIndex += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Open Settings") {
                        perm.request()
                        polling = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Done") {
                    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        apiKeyError = true
                    } else {
                        Settings.shared.apiKey = trimmed
                        onComplete()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Helpers

    private func isDone(_ index: Int) -> Bool {
        if index < PermissionKind.allCases.count {
            return statuses[PermissionKind.allCases[index]] == true
        }
        return false
    }

    private func refreshStatuses() {
        for perm in PermissionKind.allCases {
            let granted = perm.isGranted
            if statuses[perm] != granted {
                statuses[perm] = granted
                if granted, let idx = PermissionKind.allCases.firstIndex(of: perm), idx == stepIndex {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        stepIndex += 1
                    }
                }
            }
        }
    }
}
