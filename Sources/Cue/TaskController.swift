import Foundation
import AppKit

private func log(_ message: String, level: String = "INFO") {
    CueLogger.write("[task] \(message)", level: level)
}

/// Owns the coach-mode conversation loop: start_task → next_step → ask_question → complete.
/// Drives OverlayState and dispatches LLM calls. One instance per app, lives on MainActor.
@MainActor
final class TaskController {
    private let state: OverlayState
    private let pillWindowID: () -> CGWindowID
    private let frontApp: () -> String

    private struct StepRecord {
        let instruction: String
        let historyLength: Int
    }

    private var history: [LLMMessage] = []
    private var stepRecords: [StepRecord] = []
    private var lastInstruction: String = ""
    private var stepCount: Int = 0
    private var currentTask: String?
    private var inFlight: Task<Void, Never>?
    private var scratchpadSummary: String = ""

    /// Keep the last N message turns (user + assistant). 8 = 4 full turns.
    private static let historyWindow = 20

    init(state: OverlayState, pillWindowID: @escaping () -> CGWindowID, frontApp: @escaping () -> String = { "" }) {
        self.state = state
        self.pillWindowID = pillWindowID
        self.frontApp = frontApp
    }

    var isActive: Bool {
        switch state.phase {
        case .thinking, .active, .error: return true
        case .empty, .complete: return false
        }
    }

    /// User pressed Enter. Text may be empty (= "next step" when active).
    func submit(_ text: String) {
        log("submit phase=\(state.phase) text=\(text.prefix(40))")
        switch state.phase {
        case .empty, .error:
            guard !text.isEmpty else { return }
            startTask(text)
        case .active:
            if text.isEmpty {
                nextStep()
            } else {
                askQuestion(text)
            }
        case .thinking:
            guard !text.isEmpty else { return }
            // Cancel whatever is in-flight and re-dispatch with the correction injected.
            inFlight?.cancel()
            inFlight = nil
            let correction = "User correction: \(text)\n\nOverall task: \(currentTask ?? "")\n\nGiven this correction, what is the next step?"
            history.append(LLMMessage(role: .user, text: text))
            dispatch(userText: correction, advancesStep: true)
        case .complete:
            return
        }
    }

    /// Esc or pill dismiss. Aborts any in-flight call and resets state.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        currentTask = nil
        history.removeAll()
        stepRecords.removeAll()
        lastInstruction = ""
        stepCount = 0
        scratchpadSummary = ""
        state.phase = .empty
        state.currentStep = ""
        state.stepCount = 0
        state.stepHistory = []
        state.errorMessage = ""
        state.text = ""
        state.pendingAction = .none
        state.pendingActionDescription = ""
        state.awaitingApproval = false
        state.canAllowAlways = false
        state.qaAnswer = ""
    }

    func rollback(to index: Int) {
        guard index >= 0 && index < stepRecords.count else { return }
        inFlight?.cancel()
        inFlight = nil
        let record = stepRecords[index]
        stepRecords = Array(stepRecords.prefix(index + 1))
        history = Array(history.prefix(record.historyLength))
        stepCount = index + 1
        lastInstruction = record.instruction
        state.stepHistory = stepRecords.map { $0.instruction }
        state.currentStep = record.instruction
        state.stepCount = stepCount
        state.pendingAction = .none
        state.pendingActionDescription = ""
        state.awaitingApproval = false
        state.canAllowAlways = false
        state.qaAnswer = ""
        state.phase = .active
    }

    // MARK: - Flow

    func actionDenied(action: StepResponse.ActionType, app: String) {
        actionBlocked(
            action: action,
            app: app,
            reason: "Blocked by user policy for \(app). Try a different approach that doesn't require this action, or tell the user they need to do this step manually."
        )
    }

    func actionBlocked(action: StepResponse.ActionType, app: String, reason: String) {
        let name: String
        switch action {
        case .click:                       name = "click"
        case .rightClick:                  name = "right_click"
        case .type(_, _, let t):           name = "type(\"\(t.prefix(30))\")"
        case .key(let k):                  name = "key(\(k))"
        case .scroll:                      name = "scroll"
        case .navigate(let u):             name = "navigate(\(u))"
        case .openTabAndNavigate(let u):   name = "openTabAndNavigate(\(u))"
        case .shell(let c):                name = "shell(\(c.prefix(30)))"
        case .none:                        name = "none"
        }
        log("action blocked: \(name) in \(app) — \(reason)")
        state.pendingAction = .none
        state.pendingActionDescription = ""
        state.awaitingApproval = false
        state.canAllowAlways = false
        let feedback = "[\(name)] was blocked in \(app): \(reason)"
        history.append(LLMMessage(role: .user, text: feedback))
        dispatch(userText: feedback, advancesStep: false)
    }

    private func startTask(_ task: String) {
        currentTask = task
        history.removeAll()
        stepRecords.removeAll()
        stepCount = 0
        lastInstruction = ""
        state.stepHistory = []
        let userText = "Task: \(task)\n\nFirst, look at my screen and identify exactly which app is currently active and what is visible. Then, given that starting point, what is the single first step I need to take? If the first step requires a different app, the step must be switching to that app — not an action inside it."
        dispatch(userText: userText, advancesStep: true, includeScreenshot: true)
    }

    private func nextStep() {
        let userText = """
        Overall task: \(currentTask ?? "")
        Previous instruction was: '\(lastInstruction)'

        Look at my current screen carefully. Has the previous step been completed? Do you see evidence of it on the screen?

        If YES, tell me the NEXT step toward completing the overall task.
        If NO (the previous step hasn't been done yet), reconsider the approach — if the target element is not clearly visible, scroll to reveal it rather than clicking the same location again.
        """
        dispatch(userText: userText, advancesStep: true, sanitize: true)
    }

    private func pinnedHistory() -> [LLMMessage] {
        guard history.count > Self.historyWindow else { return history }
        let pinned = Array(history.prefix(2))
        let recent = Array(history.suffix(Self.historyWindow - 2))
        return pinned + recent
    }

    private func askQuestion(_ question: String) {
        guard !Settings.shared.apiKey.isEmpty else {
            state.phase = .error
            state.errorMessage = "No API key set. Open Settings from the menubar to add one."
            return
        }

        state.phase = .thinking
        state.errorMessage = ""
        state.pendingAction = .none
        state.qaAnswer = ""

        inFlight?.cancel()
        let windowID = pillWindowID()
        let cappedHistory = pinnedHistory()
        let client = AnthropicClient(settings: Settings.shared)
        let task = currentTask ?? ""
        let step = lastInstruction

        inFlight = Task { [weak self] in
            do {
                let (shot, shotSize) = try await ScreenCapture.capture(excludingWindowIDs: [windowID])
                let response = try await client.answerQuestion(
                    task: task, question: question, currentStep: step,
                    screenshot: shot, screenshotSize: shotSize, history: cappedHistory
                )
                guard !Task.isCancelled, let self else { return }
                self.history.append(LLMMessage(role: .user, text: question))
                self.history.append(LLMMessage(role: .assistant, text: response.instruction))
                self.state.qaAnswer = response.instruction
                self.state.pendingAction = response.action
                self.state.phase = .active
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.state.phase = .error
                self.state.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(userText: String, advancesStep: Bool, sanitize: Bool = false, includeScreenshot: Bool = true) {
        guard !Settings.shared.apiKey.isEmpty else {
            state.phase = .error
            state.errorMessage = "No API key set. Open Settings from the menubar to add one."
            return
        }

        state.phase = .thinking
        state.errorMessage = ""
        state.pendingAction = .none

        inFlight?.cancel()
        let windowID = pillWindowID()
        let cappedHistory = pinnedHistory()
        let client = AnthropicClient(settings: Settings.shared)
        let appContext = frontApp()
        let contextBlock = SystemInfo.currentContextBlock()
        log(" context block: \(contextBlock.prefix(200))")
        let scratchpadBlock = scratchpadSummary.isEmpty ? "" : "\n\n<scratchpad>\n\(scratchpadSummary)\n</scratchpad>"
        let enrichedText = (appContext.isEmpty ? userText : "Active app: \(appContext)\n\n\(userText)")
            + (contextBlock.isEmpty ? "" : "\n\n\(contextBlock)")
            + scratchpadBlock

        log(" dispatch begin: advances=\(advancesStep) app=\(appContext)")
        inFlight = Task { [weak self] in
            do {
                log(" capturing screen… includeScreenshot=\(includeScreenshot)")
                let (shot, shotSize) = try await ScreenCapture.capture(excludingWindowIDs: [windowID])
                log(" capture done: \(shot.count) bytes at \(shotSize)")
                log(" calling LLM…")
                let step = try await client.nextStep(
                    task: enrichedText,
                    screenshot: includeScreenshot ? shot : nil,
                    screenshotSize: shotSize,
                    history: cappedHistory,
                    onScratchpadUpdate: { [weak self] content in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let summary = try? await client.compressScratchpad(content) {
                                self.scratchpadSummary = summary
                            }
                        }
                    }
                )
                let instruction = sanitize ? ((try? await client.sanitize(step.instruction)) ?? step.instruction) : step.instruction
                var response = StepResponse(instruction: instruction, action: step.action, isComplete: step.isComplete)
                response.requiresUserInput = step.requiresUserInput
                response.targetDescription = step.targetDescription

                log(" LLM reply: \(instruction.prefix(120))")
                log(" checking guard: cancelled=\(Task.isCancelled) selfNil=\(self == nil)")
                guard !Task.isCancelled, let self else {
                    log(" GUARD FAILED — bailing before UI update")
                    return
                }
                log(" guard passed, appending history + calling handleReply")
                self.history.append(LLMMessage(role: .user, text: userText))
                self.history.append(LLMMessage(role: .assistant, text: instruction))
                self.handleReply(response, advancesStep: advancesStep)
                log(" handleReply returned; phase=\(self.state.phase)")
            } catch is CancellationError {
                log("cancelled")
                return
            } catch {
                log("error: \(error)", level: "ERROR")
                guard !Task.isCancelled, let self else { return }
                self.state.phase = .error
                self.state.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleReply(_ response: StepResponse, advancesStep: Bool) {
        log("handleReply entry done=\(response.isComplete) text=\(response.instruction.prefix(80))")

        if advancesStep {
            state.qaAnswer = ""
            if !response.instruction.isEmpty {
                lastInstruction = response.instruction
                stepCount += 1
                stepRecords.append(StepRecord(instruction: response.instruction, historyLength: history.count))
                state.stepHistory = stepRecords.map { $0.instruction }
                state.currentStep = response.instruction
            }
        } else {
            state.qaAnswer = response.instruction
        }
        state.stepCount = stepCount
        state.pendingAction = response.action
        state.pendingActionDescription = response.targetDescription

        if response.isComplete {
            if case .none = response.action, !advancesStep {
                // Q&A mode: model answered a question, stay active for follow-ups.
                state.phase = .active
            } else {
                if let task = currentTask {
                    let record = TaskRecord(
                        id: UUID().uuidString,
                        task: task,
                        completedAt: Date(),
                        steps: stepRecords.map { $0.instruction }
                    )
                    TaskHistory.save(record)
                }
                state.phase = .complete
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    guard let self, self.state.phase == .complete else { return }
                    self.cancel()
                }
            }
        } else {
            state.phase = .active
            // In auto mode with no action to execute, poll forward automatically — unless the model
            // explicitly asked to wait for the user (e.g. login, captcha).
            if state.autoMode, case .none = response.action, !response.requiresUserInput {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let self, self.state.phase == .active else { return }
                    self.nextStep()
                }
            }
        }
    }
}
