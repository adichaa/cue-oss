import AppKit
import SwiftUI
import Combine

// MARK: - Design tokens (aligned with OverlayView navy+blue system)
private let hudAccentBlue   = Color(red: 0.012, green: 0.412, blue: 0.631)  // #0369A1 primary
private let hudAccentTeal   = Color(red: 0.20,  green: 0.65,  blue: 0.50)   // success / done
private let hudAccentRose   = Color(red: 0.94,  green: 0.38,  blue: 0.42)   // failed
private let hudNavy         = Color(red: 0.059, green: 0.090, blue: 0.165)  // #0F172A backdrop

// MARK: - Per-task state

@MainActor
final class TaskHUDState: ObservableObject {
    enum Status { case running, done, failed }

    struct ActionButton: Identifiable {
        let id = UUID()
        let label: String
        let action: () -> Void
    }

    let id = UUID()
    @Published var title: String = ""
    @Published var message: String = ""
    @Published var status: Status = .running
    @Published var buttons: [ActionButton] = []
    var onReply: (() -> Void)?
    var onCancel: (() -> Void)?

    func setButtons(_ specs: [(label: String, action: () -> Void)]) {
        buttons = specs.map { ActionButton(label: $0.label, action: $0.action) }
    }
}

extension TaskHUDState: Identifiable {}

// MARK: - Shared column manager (one panel, all chips stack inside it)

@MainActor
final class TaskHUDManager: ObservableObject {
    static let shared = TaskHUDManager()
    @Published private(set) var states: [TaskHUDState] = []
    private var panel: NSPanel?

    private init() {}

    func add(_ state: TaskHUDState) {
        states.append(state)
        showPanelIfNeeded()
    }

    func remove(_ state: TaskHUDState) {
        states.removeAll { $0.id == state.id }
        if states.isEmpty { hidePanel() }
    }

    private func showPanelIfNeeded() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let width: CGFloat = 320

        let p = NSPanel(
            contentRect: NSRect(x: vf.maxX - width - 8, y: vf.minY, width: width, height: vf.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: TaskHUDColumnView(manager: self))
        hosting.sizingOptions = []
        p.contentView = hosting
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p
        p.orderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Column view (VStack of chips, right-aligned, animates together)

private struct TaskHUDColumnView: View {
    @ObservedObject var manager: TaskHUDManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(manager.states) { state in
                TaskHUDChip(state: state, onDismiss: {
                    TaskHUDManager.shared.remove(state)
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8)
    }
}

// MARK: - Per-task handle (public API)

@MainActor
final class TaskHUD {
    private var state: TaskHUDState?
    private var registered = false

    init() {}

    func present(title: String, message: String) {
        CueLogger.write("[hud] present: \(title)")
        let s = TaskHUDState()
        s.title = title
        s.message = message
        s.status = .running
        state = s
        TaskHUDManager.shared.add(s)
        registered = true
    }

    func update(message: String) { state?.message = message }

    var onCancel: (() -> Void)? {
        get { state?.onCancel }
        set { state?.onCancel = newValue }
    }

    func complete(message: String, onReply: (() -> Void)? = nil, followUpButtons: [(label: String, action: () -> Void)] = []) {
        state?.message = message
        state?.status = .done
        state?.onReply = onReply
        if !followUpButtons.isEmpty { state?.setButtons(followUpButtons) }
    }

    func restart(message: String) {
        state?.status = .running
        state?.message = message
        state?.buttons = []
        state?.onReply = nil
    }

    func fail(message: String) {
        state?.message = message
        state?.status = .failed
    }

    func dismiss() {
        guard let s = state, registered else { return }
        TaskHUDManager.shared.remove(s)
        state = nil
        registered = false
    }
}

// MARK: - Chip view

private struct TaskHUDChip: View {
    @ObservedObject var state: TaskHUDState
    let onDismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if hovered {
                contentStrip
                    .transition(.opacity)
            }
            ballTile
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hudNavy.opacity(hovered ? 0.94 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(hovered ? 0.18 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(hudAccentBlue.opacity(hovered ? 0.22 : 0), lineWidth: 0.75)
                )
        )
        .shadow(color: .black.opacity(hovered ? 0.44 : 0), radius: 20, x: -2, y: 8)
        .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 5, x: -1, y: 2)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                hovered = h
            }
        }
    }

    private var ballTile: some View {
        CueBall(status: state.status)
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
            .frame(width: 44, height: 44)
    }

    private var contentStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    statusBadge
                }
                Spacer(minLength: 0)
                if state.status == .done, let onReply = state.onReply {
                    Button(action: onReply) {
                        Image(systemName: "arrow.turn.up.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .help("Follow up")
                }
                Button(action: {
                    if state.status == .running { state.onCancel?() }
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }

            Text(state.message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !state.buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(state.buttons) { btn in
                        Button(btn.label, action: btn.action)
                            .buttonStyle(HUDButtonStyle())
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .frame(width: 240)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.status {
        case .running:
            Text("running").font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
        case .done:
            Text("done").font(.system(size: 10, weight: .medium))
                .foregroundStyle(.green)
        case .failed:
            Text("failed").font(.system(size: 10, weight: .medium))
                .foregroundStyle(hudAccentRose.opacity(0.88))
        }
    }
}

// MARK: - Cue Ball

private struct CueBall: View {
    let status: TaskHUDState.Status
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [.white, Color(white: 0.80)],
                    center: UnitPoint(x: 0.35, y: 0.28),
                    startRadius: 0, endRadius: 10
                ))
            Circle()
                .fill(RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.2)],
                    center: UnitPoint(x: 0.72, y: 0.75),
                    startRadius: 1, endRadius: 9
                ))
            Ellipse()
                .fill(Color.white.opacity(0.65))
                .frame(width: 5, height: 3.5)
                .offset(x: -2.5, y: -3)
                .blur(radius: 1)
            Circle()
                .strokeBorder(statusColor.opacity(pulse ? 0.95 : 0.35), lineWidth: 1.5)
                .scaleEffect(pulse ? 1.18 : 1.0)
                .shadow(color: status == .running ? Color(red: 0.2, green: 0.5, blue: 1.0).opacity(pulse ? 0.70 : 0.10) : .clear, radius: 4)
        }
        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = status == .running }
        .onChange(of: status) { _, s in pulse = s == .running }
    }

    private var statusColor: Color {
        switch status {
        case .running: Color(red: 0.2, green: 0.5, blue: 1.0)
        case .done:    .green
        case .failed:  .red
        }
    }
}

// MARK: - Button style

private struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.45 : 0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hudAccentBlue.opacity(configuration.isPressed ? 0.18 : 0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(hudAccentBlue.opacity(0.35), lineWidth: 0.5)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.62), value: configuration.isPressed)
    }
}
