import AppKit
import SwiftUI
import Combine

final class OverlayPanel: NSPanel {
    let state = OverlayState()
    var onDismiss: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: ((String) -> Void)?
    var onRollback: ((Int) -> Void)?
    var onApprove: (() -> Void)?
    var onAllowAlways: (() -> Void)?
    var onSkip: (() -> Void)?
    var onClearReply: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    private static let baseHeight: CGFloat = 64

    init() {
        let size = NSSize(width: 560, height: Self.baseHeight)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .vibrantDark)

        sharingType = .readWrite

        var view = OverlayView(
            state: state,
            onSubmit: { [weak self] text in self?.onSubmit?(text) },
            onDismiss: { [weak self] in self?.handleEscape() },
            onRollback: { [weak self] index in self?.onRollback?(index) },
            onApprove: { [weak self] in self?.onApprove?() },
            onAllowAlways: { [weak self] in self?.onAllowAlways?() },
            onSkip: { [weak self] in self?.onSkip?() },
            onClearReply: { [weak self] in self?.onClearReply?() }
        )
        view.onHeightChange = { [weak self] height in
            self?.applyHeight(height)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "q" {
            orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onDismiss?()
    }

    /// CGWindowID for ScreenCaptureKit exclusion — lets cue photograph
    /// the screen without photographing its own pill.
    var cgWindowID: CGWindowID { CGWindowID(windowNumber) }

    func present() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.maxY - frame.height - 24
        )
        setFrameOrigin(origin)
        level = .floating
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func setRecording(_ recording: Bool) {
        state.isRecording = recording
    }

    func setInputText(_ text: String) {
        state.text = text
    }

    // MARK: - Private

    private func handleEscape() {
        if let onEscape {
            onEscape()
        } else {
            orderOut(nil)
        }
    }

    private func applyHeight(_ target: CGFloat) {
        let current = frame.height
        guard abs(current - target) > 0.5 else { return }

        var newFrame = frame
        newFrame.origin.y -= (target - current)
        newFrame.size.height = target
        // animate: false — SwiftUI's own spring drives the height changes; adding
        // a second macOS window animation causes the panel to lag and show empty glass.
        setFrame(newFrame, display: false, animate: false)
    }
}
