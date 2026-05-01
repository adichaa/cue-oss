import SwiftUI
import AppKit
import Combine

// MARK: - Design tokens  (#0F172A navy + #0369A1 blue accent system)
private let cueAccentBlue   = Color(red: 0.012, green: 0.412, blue: 0.631)  // #0369A1 primary
private let cueAccentAmber  = Color(red: 0.96,  green: 0.74,  blue: 0.32)   // auto mode indicator
private let cueAccentRose   = Color(red: 0.94,  green: 0.38,  blue: 0.42)   // error / recording
private let cueNavy         = Color(red: 0.059, green: 0.090, blue: 0.165)  // #0F172A backdrop tint

@MainActor
final class OverlayState: ObservableObject {
    enum Phase: Equatable {
        case empty
        case thinking
        case active
        case complete
        case error
    }

    @Published var text: String = ""
    @Published var isRecording: Bool = false
    @Published var phase: Phase = .empty
    @Published var currentStep: String = ""
    @Published var stepHistory: [String] = []
    @Published var stepCount: Int = 0
    @Published var errorMessage: String = ""
    @Published var pendingAction: StepResponse.ActionType = .none
    @Published var qaAnswer: String = ""
    @Published var autoMode: Bool = false
    @Published var awaitingApproval: Bool = false
    @Published var canAllowAlways: Bool = false
    @Published var pendingActionDescription: String = ""
    @Published var frontApp: String = ""
    @Published var backgroundMode: Bool = false
    @Published var bgReplyTitle: String = ""

    private(set) var inputHistory: [String] = []
    var historyIndex: Int = -1

    func pushHistory(_ text: String) {
        guard !text.isEmpty, inputHistory.last != text else { return }
        inputHistory.append(text)
        historyIndex = -1
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    var onRollback: ((Int) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onApprove: (() -> Void)?
    var onAllowAlways: (() -> Void)?
    var onSkip: (() -> Void)?
    var onClearReply: (() -> Void)?

    @FocusState private var focused: Bool
    @State private var historyDraft: String = ""
    @State private var isShowingFirstTaskHint = false
    @State private var showSuggestions = true
    @State private var inputHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if !state.bgReplyTitle.isEmpty {
                replyContextBadge
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -4)),
                        removal: .opacity
                    ))
            }
            if showsStepArea {
                stepArea
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -6)),
                        removal: .opacity
                    ))
            }

            if state.phase == .empty && state.bgReplyTitle.isEmpty && showSuggestions {
                suggestionsRow
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -4)),
                        removal: .opacity.combined(with: .offset(y: -4))
                    ))
            }

            if state.phase == .empty {
                Text(modeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: modeLabel)
            }

            inputRow
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showsStepArea)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.bgReplyTitle.isEmpty)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showSuggestions)
        .onChange(of: state.text) { _, newText in
            if newText.isEmpty {
                withAnimation { showSuggestions = true }
            } else if showSuggestions {
                withAnimation(.easeOut(duration: 0.15)) { showSuggestions = false }
            }
        }
        .onChange(of: state.phase) { _, p in
            if p == .empty { withAnimation { showSuggestions = true } }
        }
        .background(
            GeometryReader { geo in
                Color.clear.onAppear { onHeightChange?(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in onHeightChange?(h) }
            }
        )
        .background(pillBackground)
        .onAppear { focused = true }
        .onChange(of: state.phase) { _, newPhase in
            if newPhase == .complete && !UserDefaults.standard.bool(forKey: "cue.hasCompletedFirstTask") {
                UserDefaults.standard.set(true, forKey: "cue.hasCompletedFirstTask")
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.4)) {
                    isShowingFirstTaskHint = true
                }
            }
            if newPhase != .thinking && newPhase != .complete {
                focused = true
                isShowingFirstTaskHint = false
            }
        }
    }

    // MARK: - Subviews

    private var replyContextBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.up.left")
                .font(.system(size: 10, weight: .semibold))
            Text(state.bgReplyTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: {
                state.bgReplyTitle = ""
                onClearReply?()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.45))
    }

    private var modeLabel: String {
        if state.backgroundMode { return "agent · complex tasks in the background" }
        if state.autoMode       { return "autonomous · i'll just do it for you" }
        return "coach · i'll guide you step by step"
    }

    private var inputRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("cue")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, 20)
                .padding(.top, 11)

            Divider()
                .frame(height: 18)
                .overlay(.white.opacity(0.12))
                .padding(.top, 10)

            if state.phase == .thinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .padding(.top, 11)
            }

            MultilineTextInput(
                text: $state.text,
                placeholder: promptText,
                isDisabled: state.phase == .complete && state.bgReplyTitle.isEmpty,
                onSubmit: submit,
                onEscape: onDismiss,
                onHistoryUp: {
                    let history = state.inputHistory
                    guard !history.isEmpty else { return }
                    if state.historyIndex == -1 { historyDraft = state.text }
                    let next = state.historyIndex == -1 ? history.count - 1 : max(0, state.historyIndex - 1)
                    state.historyIndex = next
                    state.text = history[next]
                },
                onHistoryDown: {
                    let history = state.inputHistory
                    guard state.historyIndex != -1 else { return }
                    if state.historyIndex == history.count - 1 {
                        state.historyIndex = -1
                        state.text = historyDraft
                    } else {
                        state.historyIndex = state.historyIndex + 1
                        state.text = history[state.historyIndex]
                    }
                },
                onHeightChange: { h in
                    inputHeight = h
                }
            )
            .frame(height: inputHeight)
            .padding(.trailing, 16)

            RecordingDot(active: state.isRecording)
                .frame(width: 8, height: 8)
                .padding(.top, 15)

            HStack(spacing: 4) {
                ModeButton(
                    icon: state.autoMode ? "bolt.fill" : "bolt.slash",
                    isActive: state.autoMode,
                    activeColor: cueAccentAmber,
                    action: {
                        state.autoMode.toggle()
                        if state.autoMode { state.backgroundMode = false }
                    }
                )
                .help(state.autoMode ? "Autonomous mode — tap to switch to Coach" : "Coach mode — tap to switch to Autonomous")

                ModeButton(
                    icon: state.backgroundMode ? "moon.fill" : "moon",
                    isActive: state.backgroundMode,
                    activeColor: .indigo,
                    invertActive: true,
                    action: {
                        state.backgroundMode.toggle()
                        if state.backgroundMode { state.autoMode = false }
                    }
                )
                .help(state.backgroundMode ? "Agent mode on — task runs while you work" : "Agent mode off")
            }
            .padding(.top, 6)
            .padding(.trailing, 16)
        }
    }

    @ViewBuilder
    private var stepArea: some View {
        switch state.phase {
        case .active:
            activeStepList
        case .error:
            errorRow
        case .complete:
            completeRow
        case .empty, .thinking:
            EmptyView()
        }
    }

    private var activeStepList: some View {
        let history = state.stepHistory
        // Show at most 5 total rows; trim oldest past steps if needed
        let pastSteps: [(index: Int, text: String)] = {
            guard history.count > 1 else { return [] }
            let past = history.dropLast()
            let allPast = past.enumerated().map { (index: $0.offset, text: $0.element) }
            let maxPast = 4
            if allPast.count > maxPast {
                return Array(allPast.suffix(maxPast))
            }
            return allPast
        }()

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pastSteps, id: \.index) { item in
                    PastStepRow(text: item.text, index: item.index, onTap: {
                        onRollback?(item.index)
                    })
                }

                if let currentHistoryStep = history.last, !currentHistoryStep.isEmpty {
                    CurrentStepRow(text: currentHistoryStep)
                }

                if !state.qaAnswer.isEmpty {
                    QAAnswerRow(text: state.qaAnswer)
                }

                if state.awaitingApproval {
                    ApprovalRow(
                        canAllowAlways: state.canAllowAlways,
                        onApprove: { onApprove?() },
                        onAllowAlways: { onAllowAlways?() },
                        onSkip: { onSkip?() }
                    )
                }
            }
        )
    }

    private var errorRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(cueAccentRose)
                .padding(.top, 3)
            Text(state.errorMessage.isEmpty ? "Something went wrong." : state.errorMessage)
                .font(.system(size: 13))
                .foregroundStyle(cueAccentRose.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var completeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green.opacity(0.88))
                Text("done")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
                Spacer()
            }
            if isShowingFirstTaskHint {
                Text("Tip: type qq anywhere to open cue · qqq for voice")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.36))
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
    }

    private var pillBackground: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow)
            // Navy tint for professional depth
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(cueNavy.opacity(0.30))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.12))
            // Top-edge inner glass highlight
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.06), .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.38)
                    )
                )
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [cueAccentBlue.opacity(0.28), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var suggestionsRow: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let suggestions: [String]
        if state.backgroundMode {
            suggestions = ["Research X and write a report", "Fix all lint errors in my repo", "Find and clean up duplicate files"]
        } else if state.autoMode {
            if hour < 12 {
                suggestions = ["Commit my changes", "Run my tests and summarise", "Send my draft email"]
            } else if hour < 18 {
                suggestions = ["Pull latest and run tests", "Fill in this form for me", "Push and open a PR"]
            } else {
                suggestions = ["Push my branch and open a PR", "Archive my read emails", "Check for failed CI runs"]
            }
        } else {
            if hour < 12 {
                suggestions = ["How do I set this up?", "Walk me through deploying", "Explain this error"]
            } else if hour < 18 {
                suggestions = ["How do I rebase safely?", "Guide me through this API", "What does this code do?"]
            } else {
                suggestions = ["How do I undo my last commit?", "Walk me through this error", "Explain this config"]
            }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) {
                        state.text = suggestion
                        focused = true
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 48)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Helpers

    private var showsStepArea: Bool {
        switch state.phase {
        case .active, .error, .complete: return true
        case .empty, .thinking: return false
        }
    }

    private var promptText: String {
        if !state.bgReplyTitle.isEmpty { return "follow up…" }
        switch state.phase {
        case .empty:    return state.isRecording ? "Listening…" : "What do you need help with?"
        case .thinking: return "steer…"
        case .active:   return state.isRecording ? "Listening…" : "↵ next step · type to ask"
        case .error:    return "↵ retry · or new task"
        case .complete: return ""
        }
    }

    private func submit() {
        guard !state.awaitingApproval else { return }
        let trimmed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state.phase {
        case .empty, .error:
            guard !trimmed.isEmpty else { return }
            state.pushHistory(trimmed)
            onSubmit(trimmed)
            state.text = ""
        case .active:
            if !trimmed.isEmpty { state.pushHistory(trimmed) }
            onSubmit(trimmed)
            state.text = ""
        case .thinking:
            guard !trimmed.isEmpty else { return }
            state.pushHistory(trimmed)
            onSubmit(trimmed)
            state.text = ""
        case .complete:
            if !state.bgReplyTitle.isEmpty && !trimmed.isEmpty {
                state.pushHistory(trimmed)
                onSubmit(trimmed)
                state.text = ""
            }
            return
        }
    }
}

// MARK: - Step row components

private struct PastStepRow: View {
    let text: String
    let index: Int
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 14)
                    .padding(.top, 2)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(hovered ? 0.65 : 0.40))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .scaleEffect(hovered ? 1.01 : 1.0, anchor: .leading)
        .onHover { h in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { hovered = h }
        }
        .help("Roll back to step \(index + 1)")
    }
}

private struct CurrentStepRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.forward.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 12)
        }
    }
}

private struct QAAnswerRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.38))
                .frame(width: 14)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

private struct ApprovalRow: View {
    let canAllowAlways: Bool
    let onApprove: () -> Void
    let onAllowAlways: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ApprovalButton(label: "Allow", color: .white.opacity(0.85), action: onApprove)
            if canAllowAlways {
                Text("·").foregroundStyle(.white.opacity(0.20)).padding(.horizontal, 8)
                ApprovalButton(label: "Allow Always", color: cueAccentAmber.opacity(0.88), action: onAllowAlways)
            }
            Text("·").foregroundStyle(.white.opacity(0.20)).padding(.horizontal, 8)
            ApprovalButton(label: "Skip", color: .white.opacity(0.32), action: onSkip)
        }
        .padding(.top, 4)
    }
}

private struct ApprovalButton: View {
    let label: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color.opacity(hovered ? 1.0 : 0.75))
        }
        .buttonStyle(ScaleButtonStyle())
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { hovered = h }
        }
    }
}

// MARK: - Support views

private struct SuggestionChip: View {
    let text: String
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(hovered ? 0.65 : 0.38))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(hovered ? 0.07 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { hovered = h }
        }
    }
}

private struct RecordingDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? cueAccentRose : .white.opacity(0.28))
            .scaleEffect(active && pulse ? 1.30 : 1.0)
            .shadow(color: active ? cueAccentRose.opacity(pulse ? 0.80 : 0.15) : .clear, radius: pulse ? 5 : 1)
            .animation(active ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : .spring(response: 0.3, dampingFraction: 0.7), value: pulse)
            .onAppear { pulse = true }
    }
}

private struct ModeButton: View {
    let icon: String
    let isActive: Bool
    let activeColor: Color
    var invertActive: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? (invertActive ? .white : activeColor) : .white.opacity(hovered ? 0.60 : 0.40))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? (invertActive ? activeColor : activeColor.opacity(0.14)) : (hovered ? .white.opacity(0.08) : .clear))
                )
                .scaleEffect(hovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { hovered = h }
        }
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
