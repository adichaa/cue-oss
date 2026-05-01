import AppKit
import SwiftUI

struct MultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isDisabled: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onHistoryUp: (() -> Void)?
    var onHistoryDown: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    static let font    = NSFont.systemFont(ofSize: 14)
    static let maxLines: CGFloat = 4
    static let vPad:   CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Apple's factory gives a properly wired NSScrollView + NSTextView.
        // The text view is vertically resizable and the scroll view scrolls it.
        let sv = NSTextView.scrollableTextView() as! NSScrollView
        sv.hasVerticalScroller = false
        sv.autohidesScrollers  = true
        sv.drawsBackground     = false
        sv.borderType          = .noBorder

        let tv = sv.documentView as! NSTextView
        tv.isRichText     = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font            = Self.font
        tv.textColor       = .white
        tv.insertionPointColor = .white
        tv.isEditable      = true
        tv.isSelectable    = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled  = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: Self.vPad)
        tv.textContainer?.lineFragmentPadding = 0
        tv.delegate = context.coordinator

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? NSTextView else { return }

        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel
        }
        tv.isEditable = !isDisabled

        // Placeholder: drawn by a transparent overlay text view.
        if let ph = sv.superview?.subviews.compactMap({ $0 as? PlaceholderLabel }).first {
            ph.stringValue = placeholder
            ph.isHidden    = !text.isEmpty
        } else {
            let ph = PlaceholderLabel()
            ph.font        = Self.font
            ph.textColor   = .white.withAlphaComponent(0.35)
            ph.stringValue = placeholder
            ph.isHidden    = !text.isEmpty
            ph.isEditable  = false
            ph.isSelectable = false
            ph.drawsBackground = false
            ph.isBordered  = false
            ph.translatesAutoresizingMaskIntoConstraints = false
            sv.superview?.addSubview(ph)
            // will be positioned in layout; use a simple offset matching vPad
        }

        context.coordinator.reportHeight(tv)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTextInput

        init(_ parent: MultilineTextInput) { self.parent = parent }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            reportHeight(tv)
            // Scroll on the next run-loop tick after layout settles.
            DispatchQueue.main.async {
                tv.scrollRangeToVisible(tv.selectedRange())
            }
        }

        func reportHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let w = tv.bounds.width
            guard w > 0 else { return }
            tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            let used    = lm.usedRect(for: tc).height
            let content = used + MultilineTextInput.vPad * 2
            let lineH   = MultilineTextInput.font.pointSize * 1.4
            let cap     = lineH * MultilineTextInput.maxLines + MultilineTextInput.vPad * 2
            let visible = max(lineH + MultilineTextInput.vPad * 2, min(content, cap))
            parent.onHeightChange?(visible)
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape(); return true
            case #selector(NSResponder.moveUp(_:)):
                if isOnFirstLine(tv), let up = parent.onHistoryUp { up(); return true }
            case #selector(NSResponder.moveDown(_:)):
                if isOnLastLine(tv), let down = parent.onHistoryDown { down(); return true }
            default: break
            }
            return false
        }

        private func isOnFirstLine(_ tv: NSTextView) -> Bool {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return true }
            let loc = tv.selectedRange().location
            let gi = loc > 0 ? lm.glyphIndexForCharacter(at: loc - 1) : 0
            guard lm.numberOfGlyphs > 0 else { return true }
            let rect = lm.lineFragmentRect(forGlyphAt: min(gi, lm.numberOfGlyphs - 1), effectiveRange: nil)
            return rect.minY <= MultilineTextInput.vPad + 2
        }

        private func isOnLastLine(_ tv: NSTextView) -> Bool {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return true }
            let total = lm.numberOfGlyphs
            guard total > 0 else { return true }
            let loc = tv.selectedRange().location
            let gi = loc < tv.string.count ? lm.glyphIndexForCharacter(at: loc) : total - 1
            let cursorLineY = lm.lineFragmentRect(forGlyphAt: min(gi, total - 1), effectiveRange: nil).minY
            let lastLineY   = lm.lineFragmentRect(forGlyphAt: total - 1, effectiveRange: nil).minY
            return abs(cursorLineY - lastLineY) < 2
        }
    }
}

// Minimal NSTextField subclass used as a placeholder overlay.
private final class PlaceholderLabel: NSTextField {}
