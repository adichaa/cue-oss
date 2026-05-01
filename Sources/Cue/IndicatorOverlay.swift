import AppKit
import SwiftUI
import Combine

/// Full-screen click-through overlay that shows a visual indicator
/// (pulsing ring, text highlight, scroll arrow, etc.) over the target element.
final class IndicatorOverlay {
    private var window: NSWindow?
    private var cancellable: AnyCancellable?

    func show(for action: StepResponse.ActionType) {
        dismiss()
        let view = indicatorView(for: action)

        guard let screen = NSScreen.main else { return }
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: view)
        hosting.frame = screen.frame
        win.contentView = hosting
        win.orderFrontRegardless()
        self.window = win
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Indicator views

    private func indicatorView(for action: StepResponse.ActionType) -> AnyView {
        switch action {
        case .click(let x, let y, let elementType, let width, let height):
            return AnyView(ClickIndicator(x: x, y: y, elementType: elementType, width: width, height: height, isRightClick: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .rightClick(let x, let y, let elementType, let width, let height):
            return AnyView(ClickIndicator(x: x, y: y, elementType: elementType, width: width, height: height, isRightClick: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .scroll(let x, let y, let direction, _):
            return AnyView(ScrollIndicator(x: x, y: y, direction: direction)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .type(let x, let y, let text):
            return AnyView(TypeIndicator(x: x, y: y, text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .key(let keys):
            return AnyView(KeyIndicator(keys: keys)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .navigate(let url), .openTabAndNavigate(let url):
            return AnyView(KeyIndicator(keys: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .shell(let command):
            return AnyView(KeyIndicator(keys: "$ \(command.prefix(40))")
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        case .none:
            return AnyView(EmptyView())
        }
    }
}

// MARK: - Click indicator

private struct ClickIndicator: View {
    let x: CGFloat
    let y: CGFloat
    let elementType: StepResponse.ElementType
    let width: CGFloat
    let height: CGFloat
    let isRightClick: Bool
    @State private var pulse = false

    private var tint: Color { isRightClick ? .orange : .blue }

    private var isTextLike: Bool {
        switch elementType {
        case .text, .link, .field: return true
        default: return false
        }
    }

    // Use model-provided size if available, otherwise fall back to sensible defaults.
    private var rectW: CGFloat { width > 0 ? width + 12 : 180 }
    private var rectH: CGFloat { height > 0 ? height + 8  : 28 }

    var body: some View {
        ZStack {
            if isTextLike {
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(pulse ? 0.30 : 0.15))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.85), lineWidth: 1.5))
                    .frame(width: rectW, height: rectH)
                    .position(x: x, y: y)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            } else {
                Circle()
                    .strokeBorder(tint.opacity(0.9), lineWidth: 2.5)
                    .frame(width: pulse ? 48 : 32, height: pulse ? 48 : 32)
                    .position(x: x, y: y)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                Circle()
                    .fill(tint.opacity(0.25))
                    .frame(width: 18, height: 18)
                    .position(x: x, y: y)
            }
        }
        .onAppear { pulse = true }
    }
}

// MARK: - Scroll indicator

private struct ScrollIndicator: View {
    let x: CGFloat
    let y: CGFloat
    let direction: StepResponse.ScrollDirection
    @State private var animate = false

    private var chevronName: String {
        switch direction {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        }
    }

    private func chevronOffset(_ index: Int) -> CGSize {
        let base: CGFloat = animate ? 10 : 0
        let step = CGFloat(index) * 10
        switch direction {
        case .up:    return CGSize(width: 0, height: -(base + step))
        case .down:  return CGSize(width: 0, height:  (base + step))
        case .left:  return CGSize(width: -(base + step), height: 0)
        case .right: return CGSize(width:  (base + step), height: 0)
        }
    }

    private func chevronOpacity(_ index: Int) -> Double {
        animate ? Double(3 - index) / 3.0 : Double(index + 1) / 4.0
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.60))
                .frame(width: 64, height: 64)
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: chevronName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .opacity(chevronOpacity(i))
                    .offset(chevronOffset(i))
                    .animation(
                        .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(i) * 0.12),
                        value: animate
                    )
            }
        }
        .position(x: x, y: y)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { animate = true }
        }
    }
}

// MARK: - Type indicator

private struct TypeIndicator: View {
    let x: CGFloat
    let y: CGFloat
    let text: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "keyboard")
                .font(.system(size: 18))
                .foregroundColor(.white)
            if !text.isEmpty {
                Text("Type: \(text)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.7).clipShape(RoundedRectangle(cornerRadius: 10)))
        .position(x: x, y: y - 48)
    }
}

// MARK: - Key indicator

private struct KeyIndicator: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 20, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.75).clipShape(RoundedRectangle(cornerRadius: 10)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
