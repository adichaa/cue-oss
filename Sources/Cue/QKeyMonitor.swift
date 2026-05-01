import AppKit

/// Listens globally for Q key presses and fires callbacks on double- or
/// triple-tap within a short window. Requires Accessibility permission
/// (System Settings → Privacy & Security → Accessibility).
///
/// We use a listen-only NSEvent global monitor, so the Q keypresses are NOT
/// swallowed — they still reach whatever app was focused. This means the user
/// will briefly see `qq` or `qqq` in text fields before the pill opens. The
/// tradeoff is no typing latency on isolated Q presses.
final class QKeyMonitor {
    var onDouble: (() -> Void)?
    var onTriple: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timestamps: [CFTimeInterval] = []
    private let window: CFTimeInterval = 0.25
    private var pendingDouble: DispatchWorkItem?

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 12, !event.isARepeat else { return }
            self?.handleQPress()
        }
        // Local: Q presses inside our own pill (when it has focus). Let the
        // event pass through so typing still works; we're just eavesdropping.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 12, !event.isARepeat {
                self?.handleQPress()
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        pendingDouble?.cancel()
        pendingDouble = nil
        timestamps.removeAll()
    }

    private func handleQPress() {
        let now = CACurrentMediaTime()
        if let last = timestamps.last, now - last >= window {
            timestamps.removeAll()
        }
        timestamps.append(now)

        if timestamps.count >= 3 {
            timestamps.removeAll()
            pendingDouble?.cancel()
            pendingDouble = nil
            onTriple?()
            return
        }

        if timestamps.count == 2 {
            pendingDouble?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.timestamps.removeAll()
                self.onDouble?()
            }
            pendingDouble = work
            DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
        }
    }

    deinit { stop() }
}
