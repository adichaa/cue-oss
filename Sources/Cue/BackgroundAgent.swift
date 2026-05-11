import Foundation
import UserNotifications

final class BackgroundAgent {
    let id: String = UUID().uuidString
    let task: String
    private let client: AnthropicClient
    private let sidecar = PlaywrightSidecar()
    private var runTask: Task<Void, Never>?
    private let logFileHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "com.cue.bgagent.log")

    var onStatusUpdate: ((String) -> Void)?
    var onComplete: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onResume: (() -> Void)?
    var onSpawnAgent: ((String, String?, [String]?) async -> String)?

    private var conversationMessages: [[String: Any]] = []
    private var scratchpad: String = ""
    private var finished = false
    private var activeProcesses: [Process] = []
    private let processLock = NSLock()

    let model: String?
    let toolsMode: [String]?
    let isSubAgent: Bool

    @MainActor init(task: String, settings: Settings, model: String? = nil, toolsMode: [String]? = nil, isSubAgent: Bool = false) {
        self.task = task
        self.model = model
        self.toolsMode = toolsMode
        self.isSubAgent = isSubAgent
        self.client = AnthropicClient(settings: settings)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cue/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let file = dir.appendingPathComponent("\(fmt.string(from: Date()))_agent_\(id).log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: file)
    }

    @MainActor func start() {
        requestNotificationPermission()
        runTask = Task.detached { [weak self] in await self?.run() }
    }

    @MainActor func resume(message: String) {
        agentLog("[bg] follow-up: \(message)")
        requestNotificationPermission()
        var msgs = conversationMessages
        msgs.append(["role": "assistant", "content": "Ready for your follow-up."])
        msgs.append(["role": "user", "content": message])
        onResume?()
        runTask = Task.detached { [weak self] in await self?.run(initialMessages: msgs) }
    }

    @MainActor func cancel() {
        runTask?.cancel()
        Task.detached { [weak self] in await self?.sidecar.stop() }
        processLock.lock()
        let procs = activeProcesses
        processLock.unlock()
        for proc in procs {
            proc.interrupt()
            // kill the whole process group so children (chromium, node) die too
            if proc.isRunning {
                kill(-proc.processIdentifier, SIGKILL)
            }
        }
        onFailure?("cancelled")
    }

    var isRunning: Bool { runTask != nil && !finished && runTask?.isCancelled == false }

    func killSidecar() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [weak self] in
            if let pid = await self?.sidecar.processGroupID {
                kill(-pid, SIGKILL)
            }
            sem.signal()
        }
        sem.wait()
    }

    // MARK: - Private

    private func agentLog(_ message: String, level: String = "INFO") {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(fmt.string(from: Date()))] [\(level)] \(message)\n"
        logQueue.async { self.logFileHandle?.write(line.data(using: .utf8) ?? Data()) }
    }

    private func run(initialMessages: [[String: Any]]? = nil) async {
        agentLog("[bg] task: \(task)")
        var attempts = 0
        let maxRetries = 3
        while true {
            do {
                let currentScratchpad = await MainActor.run { self.scratchpad }
                let currentModel = await MainActor.run { self.model }
                let currentToolsMode = await MainActor.run { self.toolsMode }
                let currentMessages = await MainActor.run { self.conversationMessages }
                let resumeMessages = currentMessages.isEmpty ? initialMessages : currentMessages
                let (summary, messages) = try await client.runBackgroundTask(task, model: currentModel, toolsMode: currentToolsMode, initialMessages: resumeMessages, initialScratchpad: currentScratchpad, isSubAgent: isSubAgent) { [weak self] name, input in
                    guard let self else { return "cancelled" }
                    return try await self.executeTool(name: name, input: input)
                } onStep: { [weak self] step in
                    guard let self else { return }
                    Task { @MainActor [weak self] in self?.onStatusUpdate?(step) }
                } onScratchpadUpdate: { [weak self] updated in
                    guard let self else { return }
                    Task { @MainActor [weak self] in self?.scratchpad = updated }
                } onMessagesUpdate: { [weak self] updated in
                    guard let self else { return }
                    Task { @MainActor [weak self] in self?.conversationMessages = updated }
                } log: { [weak self] msg, level in
                    self?.agentLog(msg, level: level)
                }
                await MainActor.run { self.conversationMessages = messages }
                agentLog("[bg] done")
                notify(title: "Cue: Done", body: summary)
                let onComplete = await MainActor.run { self.onComplete }
                onComplete?(summary)
                break
            } catch is CancellationError {
                agentLog("[bg] cancelled")
                break
            } catch {
                attempts += 1
                if attempts <= maxRetries {
                    let delay: UInt64 = UInt64(min(30, attempts * 5)) * 1_000_000_000
                    agentLog("[bg] network error (attempt \(attempts)/\(maxRetries)), retrying in \(min(30, attempts * 5))s: \(error.localizedDescription)")
                    // Force compression before retry so a bloated context doesn't cause the same timeout again
                    let msgs = await MainActor.run { self.conversationMessages }
                    let pad  = await MainActor.run { self.scratchpad }
                    if !msgs.isEmpty {
                        if let (compressed, newScratchpad) = try? await client.compressBgHistory(msgs, task: task, scratchpad: pad) {
                            await MainActor.run {
                                self.conversationMessages = compressed
                                if !newScratchpad.isEmpty { self.scratchpad = newScratchpad }
                            }
                            agentLog("[bg] force-compressed before retry: \(msgs.count) msgs → \(compressed.count) msgs")
                        }
                    }
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    agentLog("[bg] failed: \(error.localizedDescription)")
                    notify(title: "Cue: Task failed", body: error.localizedDescription)
                    let onFailure = await MainActor.run { self.onFailure }
                    onFailure?(error.localizedDescription)
                    break
                }
            }
        }
        await sidecar.stop()
        finished = true
    }

    private func executeTool(name: String, input: [String: Any]) async throws -> String {
        switch name {
        case "run_shell":
            return try await runShell(input["command"] as? String ?? "")
        case "browser_navigate":
            let url = input["url"] as? String ?? ""
            try await sidecar.start()
            let r = try await sidecar.send(["action": "navigate", "url": url])
            return "Navigated to \(r["url"] as? String ?? url) — \(r["title"] as? String ?? "")"
        case "browser_click":
            let sel = input["selector"] as? String ?? ""
            _ = try await sidecar.send(["action": "click", "selector": sel])
            return "Clicked \(sel)"
        case "browser_type":
            let sel  = input["selector"] as? String ?? ""
            let text = input["text"] as? String ?? ""
            _ = try await sidecar.send(["action": "type", "selector": sel, "text": text])
            return "Typed into \(sel)"
        case "browser_content":
            let r = try await sidecar.send(["action": "content"])
            let content = r["content"] as? String ?? ""
            let title   = r["title"]   as? String ?? ""
            let url     = r["url"]     as? String ?? ""
            return "URL: \(url)\nTitle: \(title)\n\(content)"
        case "read_app_ui":
            let appName = input["app_name"] as? String ?? ""
            return SystemInfo.readAppUI(appName)
        case "start_agent":
            let subtask = input["task"] as? String ?? ""
            let submodel = input["model"] as? String
            let subtools = input["tools"] as? [String]
            let cb = await MainActor.run { onSpawnAgent }
            if let cb {
                let id = await cb(subtask, submodel, subtools)
                if id.isEmpty {
                    return "ERROR: agent limit reached — too many agents running. Wait for existing agents to finish before spawning more."
                }
                return "Agent started. id=\(id) — poll: ls ~/.cue/output/agent_\(id)_done.json"
            }
            return "Agent started for: \(subtask)"
        default:
            return "unknown tool: \(name)"
        }
    }

    private func runShell(_ command: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        // run in its own process group so we can kill the whole tree
        proc.qualityOfService = .utility
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        processLock.lock()
        activeProcesses.append(proc)
        processLock.unlock()
        defer {
            processLock.lock()
            activeProcesses.removeAll { $0 === proc }
            processLock.unlock()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                proc.terminationHandler = { p in
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let combined = [out, err].filter { !$0.isEmpty }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: combined.isEmpty ? "(exit \(p.terminationStatus))" : combined)
                }
                do {
                    try proc.run()
                    setpgid(proc.processIdentifier, proc.processIdentifier)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            proc.interrupt()
            kill(-proc.processIdentifier, SIGKILL)
        }
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
