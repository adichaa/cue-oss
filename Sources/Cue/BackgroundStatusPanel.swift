import AppKit
import SwiftUI
import Combine

// MARK: - Per-task state

@MainActor
final class BackgroundTaskEntry: ObservableObject, Identifiable {
    let id = UUID()
    let task: String
    @Published var status: String = "Starting…"
    @Published var done: Bool = false
    @Published var failed: Bool = false
    var onCancel: (() -> Void)?

    init(task: String) { self.task = task }
}

// MARK: - Overlay state

@MainActor
final class BackgroundOverlayState: ObservableObject {
    @Published var entries: [BackgroundTaskEntry] = []

    func add(_ entry: BackgroundTaskEntry) {
        entries.append(entry)
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }
}

// MARK: - Panel controller

@MainActor
final class BackgroundStatusPanel {
    static let shared = BackgroundStatusPanel()
    private var panel: NSPanel?
    let state = BackgroundOverlayState()

    private init() {}

    func addTask(_ task: String, onCancel: @escaping () -> Void) -> BackgroundTaskEntry {
        let entry = BackgroundTaskEntry(task: task)
        entry.onCancel = onCancel
        state.add(entry)
        showIfNeeded()
        return entry
    }

    func complete(entry: BackgroundTaskEntry, summary: String) {
        entry.status = summary
        entry.done   = true
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.state.remove(id: entry.id)
            if self.state.entries.isEmpty { self.dismiss() }
        }
    }

    func fail(entry: BackgroundTaskEntry, error: String) {
        entry.status = error
        entry.failed = true
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.state.remove(id: entry.id)
            if self.state.entries.isEmpty { self.dismiss() }
        }
    }

    private func showIfNeeded() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: BackgroundOverlayView(state: state))
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.contentView        = hosting
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = true
        p.level              = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.isMovableByWindowBackground = true
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.minY + 24))
        }
        panel = p
        p.orderFront(nil)
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - SwiftUI views

private struct BackgroundOverlayView: View {
    @ObservedObject var state: BackgroundOverlayState

    var body: some View {
        VStack(spacing: 6) {
            ForEach(state.entries) { entry in
                BackgroundTaskRow(entry: entry, onCancel: {
                    entry.onCancel?()
                    state.remove(id: entry.id)
                })
            }
        }
        .padding(.vertical, 6)
        .frame(width: 400)
    }
}

private struct BackgroundTaskRow: View {
    @ObservedObject var entry: BackgroundTaskEntry
    let onCancel: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if entry.done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13))
                } else if entry.failed {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red.opacity(0.8))
                        .font(.system(size: 13))
                } else {
                    Circle()
                        .fill(Color.indigo.opacity(pulse ? 1.0 : 0.4))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.task)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Text(entry.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            if !entry.done && !entry.failed {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
        .frame(width: 400)
    }
}
