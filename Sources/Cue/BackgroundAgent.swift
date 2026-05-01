import Foundation
import UserNotifications

final class BackgroundAgent {
    let id: String = UUID().uuidString
    let task: String
    private let client: AnthropicClient
    private let sidecar = PlaywrightSidecar()
    private var runTask: Task<Void, Never>?

    var onStatusUpdate: ((String) -> Void)?
    var onComplete: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onResume: (() -> Void)?
    var onSpawnAgent: ((String) async -> String)?

    private var conversationMessages: [[String: Any]] = []
    private var finished = false

    @MainActor init(task: String, settings: Settings) {
        self.task = task
        self.client = AnthropicClient(settings: settings)
    }

    @MainActor func start() {
        requestNotificationPermission()
        runTask = Task.detached { [weak self] in await self?.run() }
    }

    @MainActor func resume(message: String) {
        CueLogger.write("[bg] follow-up: \(message)")
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
    }

    var isRunning: Bool { runTask != nil && !finished && runTask?.isCancelled == false }

    // MARK: - Private

    private func run(initialMessages: [[String: Any]]? = nil) async {
        do {
            let (summary, messages) = try await client.runBackgroundTask(task, initialMessages: initialMessages) { [weak self] name, input in
                guard let self else { return "cancelled" }
                return try await self.executeTool(name: name, input: input)
            } onStep: { [weak self] step in
                guard let self else { return }
                Task { @MainActor [weak self] in self?.onStatusUpdate?(step) }
            }
            await MainActor.run { self.conversationMessages = messages }
            notify(title: "Cue: Done", body: summary)
            let onComplete = await MainActor.run { self.onComplete }
            onComplete?(summary)
        } catch is CancellationError {
            // silently cancelled
        } catch {
            notify(title: "Cue: Task failed", body: error.localizedDescription)
            let onFailure = await MainActor.run { self.onFailure }
            onFailure?(error.localizedDescription)
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
            let cb = await MainActor.run { onSpawnAgent }
            if let cb {
                let id = await cb(subtask)
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
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try proc.run()
                        proc.waitUntilExit()
                        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let combined = [out, err].filter { !$0.isEmpty }
                            .joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: combined.isEmpty ? "(exit \(proc.terminationStatus))" : combined)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            proc.terminate()
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
