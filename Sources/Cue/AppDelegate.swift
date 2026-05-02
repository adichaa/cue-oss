import AppKit
import Carbon.HIToolbox
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Beta",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.kagi.kagimacOS",
    ]

    private var statusItem: NSStatusItem!
    private var overlay: OverlayPanel!
    private var hotKey: HotKey?
    private var qMonitor: QKeyMonitor!
    private let voice = VoiceRecorder()
    private let settingsWindow = SettingsWindowController()
    private var taskController: TaskController!
    private let indicator = IndicatorOverlay()
    private var cancellables: Set<AnyCancellable> = []
    private var lastFrontApp: String = ""
    private let approvalManager = ApprovalManager()
    private var backgroundAgents: [BackgroundAgent] = []
    private static let maxAgents = 10
    private var activeReplyAgent: BackgroundAgent?
    private var enterMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CueLogger.setup()
        _ = PolicyEngine.shared  // ensure ~/.cue/settings.yaml is created on first launch
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "cue"
            button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        }

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Toggle cue", action: #selector(toggleOverlay), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.command, .shift]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let runBg = NSMenuItem(title: "Run in Background…", action: #selector(runInBackground), keyEquivalent: "")
        runBg.target = self
        menu.addItem(runBg)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        overlay = OverlayPanel()
        taskController = TaskController(
            state: overlay.state,
            pillWindowID: { [weak overlay] in overlay?.cgWindowID ?? 0 },
            frontApp: { [weak self] in self?.lastFrontApp ?? "" }
        )

        // Track the last non-cue foreground app so each step knows the current context.
        // Seed with current frontmost app at launch.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           let name = app.localizedName {
            lastFrontApp = name
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier,
               let name = app.localizedName {
                Task { @MainActor [weak self] in
                    self?.lastFrontApp = name
                    self?.overlay.state.frontApp = name
                }
            }
        }

        overlay.onSubmit = { [weak self] text in
            guard let self else { return }
            if let agent = self.activeReplyAgent, !self.overlay.state.bgReplyTitle.isEmpty {
                guard !text.isEmpty else { return }
                agent.resume(message: text)
                self.clearReplyContext()
                self.overlay.orderOut(nil)
            } else if self.overlay.state.backgroundMode && self.overlay.state.phase == .empty {
                guard !text.isEmpty else { return }
                self.startBackgroundTask(text)
                self.overlay.orderOut(nil)
            } else {
                self.taskController.submit(text)
            }
        }
        overlay.onClearReply = { [weak self] in self?.clearReplyContext() }
        overlay.onRollback = { [weak self] index in
            self?.taskController.rollback(to: index)
        }
        overlay.onEscape = { [weak self] in
            guard let self else { return }
            if self.taskController.isActive {
                self.taskController.cancel()
            } else {
                self.overlay.orderOut(nil)
            }
        }
        overlay.onDismiss = { [weak self] in
            self?.voice.stop()
            self?.overlay.setRecording(false)
            self?.taskController.cancel()
            self?.indicator.dismiss()
            self?.approvalManager.reset()
            self?.removeEnterMonitor()
        }

        overlay.state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if phase == .active {
                    self?.installEnterMonitor()
                } else {
                    self?.removeEnterMonitor()
                }
            }
            .store(in: &cancellables)

        // Show/update indicator and handle auto-mode execution.
        overlay.state.$pendingAction
            .receive(on: RunLoop.main)
            .sink { [weak self] action in
                guard let self else { return }
                if case .none = action {
                    self.indicator.dismiss()
                } else {
                    self.indicator.show(for: action)
                    if self.overlay.state.autoMode {
                        self.evaluateApproval(for: action)
                    }
                }
            }
            .store(in: &cancellables)

        overlay.onApprove     = { [weak self] in self?.executeAndContinue() }
        overlay.onAllowAlways = { [weak self] in
            guard let self else { return }
            PolicyEngine.shared.writeAllow(app: self.lastFrontApp, action: self.overlay.state.pendingAction)
            self.executeAndContinue()
        }
        overlay.onSkip = { [weak self] in
            self?.overlay.state.awaitingApproval = false
        }

        // Backup hotkey — always works, no Accessibility permission required.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.toggleOverlay()
        }

        // Q-tap monitor. Prompts for Accessibility permission on first run.
        qMonitor = QKeyMonitor()
        // Defer by one runloop so the final Q keypress finishes landing in any
        // focused text field before our strip-trailing-Qs runs.
        qMonitor.onDouble = { [weak self] in
            DispatchQueue.main.async { self?.togglePill() }
        }
        qMonitor.onTriple = { [weak self] in
            DispatchQueue.main.async { self?.toggleVoice() }
        }
        qMonitor.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            PermissionWalkthroughController.shared.showIfNeeded {
                Settings.shared.markLaunched()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.settingsWindow.show()
                    self?.overlay.present()
                }
            }
        }

        wireVoiceCallbacks()
    }

    private func activateFrontApp() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == lastFrontApp }) else { return }
        app.activate()
    }

    private func isSupportedBrowser(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        guard let bundleID = app.bundleIdentifier else { return false }
        return Self.browserBundleIDs.contains(bundleID)
    }

    // MARK: - Auto mode

    private func evaluateApproval(for action: StepResponse.ActionType) {
        let desc        = overlay.state.pendingActionDescription
        let instruction = overlay.state.currentStep
        let app         = lastFrontApp
        let highStake   = approvalManager.isHighStake(action: action, targetDescription: desc, instruction: instruction)
        PolicyEngine.shared.ensureAppFile(for: app)

        // Policy engine: deny blocks immediately; allow skips prompt.
        // High-stake actions are never auto-allowed regardless of policy.
        let policy = PolicyEngine.shared.resolve(action: action, app: app)
        CueLogger.write("[approval] action=\(action) app=\(app) policy=\(policy) highStake=\(highStake)")
        switch policy {
        case .deny:
            CueLogger.write("[approval] denied by policy")
            taskController.actionDenied(action: action, app: app)
            return
        case .allow where !highStake:
            CueLogger.write("[approval] auto-approved by policy")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.executeAndContinue()
            }
            return
        default:
            break
        }

        // Ask: high-stake always prompts; non-high-stake shows "Allow Always".
        CueLogger.write("[approval] prompting user — highStake=\(highStake)")
        overlay.state.canAllowAlways = !highStake
        overlay.state.awaitingApproval = true
    }

    private func executeAndContinue() {
        let action = overlay.state.pendingAction
        overlay.state.awaitingApproval = false
        overlay.state.pendingAction = .none
        overlay.state.pendingActionDescription = ""
        indicator.dismiss()
        // key actions: HID tap so system shortcuts (cmd+space etc.) work, activate front app first.
        // type actions: postToPid normally, but fall back to HID tap if something else (e.g. Spotlight)
        //   has grabbed focus since the last action — detected by frontmost app differing from lastFrontApp.
        let lastApp = lastFrontApp
        let needsActivate = { () -> Bool in
            switch action {
            case .key, .navigate, .openTabAndNavigate: return true
            default: return false
            }
        }()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if needsActivate {
                self?.activateFrontApp()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let resolvedPid = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == lastApp })?.processIdentifier
            let currentFrontApp = NSWorkspace.shared.frontmostApplication

            switch action {
            case .scroll:
                for _ in 0..<5 {
                    await ActionExecutor.execute(action, targetPid: resolvedPid)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            case .type:
                let currentFront = NSWorkspace.shared.frontmostApplication
                let currentName = currentFront?.localizedName ?? ""
                let isSystemOverlay = currentFront?.bundleIdentifier?.hasPrefix("com.apple") == true
                    && currentName != lastApp
                let typePid = isSystemOverlay ? nil : resolvedPid
                CueLogger.write("type target: \(isSystemOverlay ? "HID tap (\(currentName) has focus)" : lastApp)")
                await ActionExecutor.execute(action, targetPid: typePid)
            case .navigate(let url):
                guard self?.isSupportedBrowser(currentFrontApp) == true else {
                    let appName = currentFrontApp?.localizedName ?? lastApp
                    CueLogger.write("refusing navigate(\(url)) in non-browser app: \(appName)", level: "WARN")
                    self?.taskController.actionBlocked(
                        action: action,
                        app: appName,
                        reason: "Cue can only run browser URL navigation in a supported browser app."
                    )
                    return
                }
                await ActionExecutor.execute(.key(keys: "cmd+l"), targetPid: resolvedPid)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await ActionExecutor.execute(.type(x: 0, y: 0, text: url), targetPid: resolvedPid)
                try? await Task.sleep(nanoseconds: 150_000_000)
                await ActionExecutor.execute(.key(keys: "return"), targetPid: resolvedPid)
            case .openTabAndNavigate(let url):
                guard self?.isSupportedBrowser(currentFrontApp) == true else {
                    let appName = currentFrontApp?.localizedName ?? lastApp
                    CueLogger.write("refusing openTabAndNavigate(\(url)) in non-browser app: \(appName)", level: "WARN")
                    self?.taskController.actionBlocked(
                        action: action,
                        app: appName,
                        reason: "Cue can only open tabs and navigate URLs in a supported browser app."
                    )
                    return
                }
                await ActionExecutor.execute(.key(keys: "cmd+t"), targetPid: resolvedPid)
                try? await Task.sleep(nanoseconds: 400_000_000)
                await ActionExecutor.execute(.key(keys: "cmd+l"), targetPid: resolvedPid)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await ActionExecutor.execute(.type(x: 0, y: 0, text: url), targetPid: resolvedPid)
                try? await Task.sleep(nanoseconds: 150_000_000)
                await ActionExecutor.execute(.key(keys: "return"), targetPid: resolvedPid)
            default:
                await ActionExecutor.execute(action, targetPid: resolvedPid)
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.taskController.submit("")
        }
    }

    @objc private func toggleOverlay() {
        if overlay.isVisible && overlay.isOnActiveSpace {
            overlay.orderOut(nil)
        } else {
            overlay.present()
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// Menubar-only apps have no main menu by default, which means
    /// ⌘C/⌘V/⌘X/⌘A don't route anywhere when a text field is focused.
    /// Installing a hidden standard Edit menu fixes paste into the
    /// API key field (and any future text input in Settings).
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // Double-Q: open in text mode, or close if already in text mode.
    private func togglePill() {
        stripTrailingQs(2)
        if overlay.isVisible && !voice.isRecording {
            overlay.orderOut(nil)
            return
        }
        voice.stop()
        overlay.setRecording(false)
        overlay.present()
    }

    // Triple-Q: open/switch to voice mode, or close if already in voice mode.
    private func toggleVoice() {
        stripTrailingQs(3)
        if overlay.isVisible && voice.isRecording {
            overlay.orderOut(nil)  // onDismiss stops voice
            return
        }
        overlay.present()
        overlay.setRecording(true)
        let existing = overlay.state.text
        Task { await voice.start(appendingTo: existing) }
    }

    /// Remove up to `count` trailing 'q'/'Q' characters from the pill's input —
    /// these leaked in because our Q-tap detector only listens, it doesn't
    /// swallow the keypresses. Only strips if the tail actually matches, so
    /// we never chew into legitimately-typed content.
    private func stripTrailingQs(_ count: Int) {
        let current = overlay.state.text
        guard current.count >= count else { return }
        let tail = current.suffix(count)
        if tail.allSatisfy({ $0 == "q" || $0 == "Q" }) {
            overlay.state.text = String(current.dropLast(count))
        }
    }

    private func wireVoiceCallbacks() {
        voice.onPartial = { [weak self] text in
            self?.overlay.setInputText(text)
        }
        voice.onError = { [weak self] error in
            self?.overlay.setRecording(false)
            print("voice error: \(error)")
        }
    }

    // MARK: - Background agent

    @objc private func runInBackground() {
        overlay.present()
        overlay.state.backgroundMode = true
    }

    @discardableResult
    private func startBackgroundTask(_ task: String) -> String {
        guard backgroundAgents.filter({ $0.isRunning }).count < Self.maxAgents else {
            CueLogger.write("[bg] agent limit reached (\(Self.maxAgents)) — ignoring: \(task.prefix(80))", level: "WARN")
            return ""
        }
        CueLogger.write("[bg] task: \(task)")
        let agent = BackgroundAgent(task: task, settings: Settings.shared)

        let companion = TaskHUD()
        companion.present(title: task, message: "Starting…")

        agent.onStatusUpdate = { step in
            CueLogger.write("[bg] \(step)")
            companion.update(message: step)
        }
        agent.onComplete = { [weak self, weak agent] summary in
            if let agent {
                let marker: [String: Any] = ["id": agent.id, "task": task, "summary": summary, "completedAt": ISO8601DateFormatter().string(from: Date())]
                let outputDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cue/output")
                try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let markerURL = outputDir.appendingPathComponent("agent_\(agent.id)_done.json")
                try? JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
            }
            companion.complete(message: summary, onReply: { [weak self, weak agent] in
                guard let self, let agent else { return }
                self.enterReplyMode(agent: agent, title: task)
            })
            self?.updateBackgroundMenu()
        }
        agent.onResume = {
            companion.restart(message: "Resuming…")
        }
        companion.onCancel = { [weak agent] in agent?.cancel() }
        agent.onFailure = { [weak self] error in
            companion.fail(message: error)
            self?.updateBackgroundMenu()
        }
        agent.onSpawnAgent = { [weak self] subtask in
            await MainActor.run { self?.startBackgroundTask(subtask) ?? "" }
        }
        backgroundAgents.append(agent)
        agent.start()
        updateBackgroundMenu()
        return agent.id
    }

    private func enterReplyMode(agent: BackgroundAgent, title: String) {
        activeReplyAgent = agent
        overlay.state.bgReplyTitle = title
        overlay.state.backgroundMode = false
        overlay.state.phase = .empty
        overlay.state.text = ""
        overlay.present()
    }

    private func clearReplyContext() {
        activeReplyAgent = nil
        overlay.state.bgReplyTitle = ""
    }

    private func updateBackgroundMenu() {
        let running = backgroundAgents.filter { $0.isRunning }
        if let button = statusItem.button {
            button.title = running.isEmpty ? "cue" : "cue (\(running.count))"
        }
    }

    // MARK: - Global Enter intercept (coach mode next-step)

    private func installEnterMonitor() {
        guard enterMonitor == nil else { return }
        enterMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            // kVK_Return = 36, kVK_ANSI_KeypadEnter = 76
            guard event.keyCode == 36 || event.keyCode == 76 else { return }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return }
            guard self.overlay.isVisible,
                  self.overlay.state.phase == .active,
                  self.overlay.state.text.isEmpty,
                  !self.overlay.state.awaitingApproval else { return }
            Task { @MainActor [weak self] in
                self?.taskController.submit("")
            }
        }
    }

    private func removeEnterMonitor() {
        if let m = enterMonitor { NSEvent.removeMonitor(m) }
        enterMonitor = nil
    }

}
