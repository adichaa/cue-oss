import Foundation
import AppKit

struct LLMMessage {
    enum Role { case user, assistant }
    let role: Role
    let text: String
}

protocol LLMProvider {
    func nextStep(task: String, screenshot: Data?, screenshotSize: CGSize, history: [LLMMessage]) async throws -> StepResponse
}

enum LLMError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case http(status: Int, body: String)
    case decode(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No API key set"
        case .invalidEndpoint: return "Endpoint URL is not valid"
        case .http(let status, let body):
            let trimmed = body.count > 240 ? String(body.prefix(240)) + "…" : body
            return "HTTP \(status): \(trimmed)"
        case .decode(let msg): return "Decode error: \(msg)"
        case .emptyResponse: return "No response from model — try again or rephrase"
        }
    }
}

/// Anthropic Messages API client. BYO endpoint — defaults to api.anthropic.com
struct AnthropicClient {
    let endpoint: String
    let apiKey: String

    // Vision tasks (screenshots) use Sonnet; text-only tasks use Haiku.
    private static let visionModel = "claude-sonnet-4-5"
    private static let fastModel   = "claude-haiku-4-5-20251001"

    @MainActor
    init(settings: Settings) {
        self.endpoint = settings.endpoint
        self.apiKey = settings.apiKey
    }

    init(endpoint: String, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    /// Minimal round-trip to confirm endpoint + key are valid.
    func ping() async throws -> String {
        try await completeRaw(
            messages: [["role": "user", "content": "say pong"]],
            system: nil,
            maxTokens: 10,
            model: Self.fastModel,
            tools: nil,
            beta: nil
        )
    }

    private static func bgStepDescription(name: String, input: [String: Any]) -> String {
        switch name {
        case "run_shell":
            let cmd = input["command"] as? String ?? ""
            return cmd.isEmpty ? "Running shell…" : "$ \(cmd.prefix(120))"
        case "browser_navigate":
            return "Navigating to \(input["url"] as? String ?? "")"
        case "browser_click":
            return "Clicking \(input["selector"] as? String ?? "")"
        case "browser_type":
            let sel  = input["selector"] as? String ?? ""
            let text = input["text"]     as? String ?? ""
            return "Typing \"\(text.prefix(30))\" into \(sel)"
        case "browser_content":
            return "Reading page content"
        case "read_app_ui":
            return "Reading \(input["app_name"] as? String ?? "app") UI"
        case "update_scratchpad":
            return "Updating notes"
        case "start_agent":
            return "→ \(input["task"] as? String ?? "sub-agent")"
        default:
            return name
        }
    }

    func compressScratchpad(_ content: String) async throws -> String {
        try await completeRaw(
            messages: [["role": "user", "content": "Compress the following scratchpad into a tight bullet list (max 8 bullets, each ≤15 words). Keep only facts needed for future steps. Return only the bullets, no preamble.\n\n\(content)"]],
            system: nil, maxTokens: 300, model: Self.fastModel, tools: nil, beta: nil
        )
    }

    func sanitize(_ reply: String) async throws -> String {
        try await completeRaw(
            messages: [["role": "user", "content": "Clean up the instruction below. Remove any narration about what's visible on screen or whether a previous step was completed. Keep a brief affirmation (one word like 'Great!' or 'Done!') only if present — do not add one. Return only the cleaned instruction.\n\n\(reply)"]],
            system: nil,
            maxTokens: 150,
            model: Self.fastModel,
            tools: nil,
            beta: nil
        )
    }

    func answerQuestion(task: String, question: String, currentStep: String, screenshot: Data?, screenshotSize: CGSize, history: [LLMMessage]) async throws -> StepResponse {
        var userContent: [[String: Any]] = []
        if let shot = screenshot {
            userContent.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": shot.base64EncodedString()]])
        }
        userContent.append(["type": "text", "text": "Task: \(task)\nCurrent step: \(currentStep)\nQuestion: \(question)"])

        var messages: [[String: Any]] = history.map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        messages.append(["role": "user", "content": userContent])

        let system = "You are cue, a macOS coaching overlay. Answer the user's question in 1-2 sentences. Call info tools if you need context. Only call indicate_action if the question asks WHERE something is AND target_visible is true — otherwise reply in plain text."
        return try await agenticLoop(messages: messages, system: system, model: Self.visionModel, screenshotSize: screenshotSize, requireAction: false)
    }

    func nextStep(task: String, screenshot: Data?, screenshotSize: CGSize, history: [LLMMessage], onScratchpadUpdate: ((String) -> Void)? = nil) async throws -> StepResponse {
        var userContent: [[String: Any]] = []
        if let shot = screenshot {
            userContent.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": shot.base64EncodedString()]])
        }
        userContent.append(["type": "text", "text": task])

        var messages: [[String: Any]] = history.map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        messages.append(["role": "user", "content": userContent])

        let system = """
<role>You are Cue, a macOS screen agent. Each turn you receive a screenshot and decide the single best next action to take. Call indicate_action exactly once per turn with your chosen action.</role>

<action_rules>
- Use the screenshot as your primary source. Call info tools in parallel when you need multiple pieces of context at once — batch them into a single response.
- Only use 'click' when the exact target is clearly visible and unambiguous in the screenshot at those coordinates.
- Key actions fire a single press-and-release. cmd+tab and similar hold-and-cycle shortcuts do not work — call activate_app to switch apps instead.
- Mac keyboards have no Home or End key. Use cmd+left / cmd+right to jump to start/end of a line.
- When you need to replace text in a field: use cmd+a to select all this turn, then on the next turn type the complete replacement text in full — never type a partial string assuming existing text is still there.
- Prefer keyboard navigation (arrow keys, tab, return) over clicking floating UI elements — synthetic clicks on dropdowns, autocomplete, and overlays are unreliable.
- If the task requires a different app than current_context.active_app, call activate_app as a tool this turn, then immediately call indicate_action with the first real action for that app — never output action:none to ask the user to switch, and never output action:none after activate_app saying to wait.
- To navigate a browser to a URL, always use navigate_to_url or open_tab_and_navigate tools — never click the address bar manually. Use open_tab_and_navigate when preserve is true, navigate_to_url otherwise.
- cmd+t only opens a new tab in the current app. Never use it to switch to a different app.
</action_rules>

<preserve_semantics>
Each user message ends with a <current_context> block. When preserve is true, your action this turn must be one of:
1. An action within the current window that does not change which app or document/site is shown — clicking UI elements, typing into focused fields, scrolling, keyboard shortcuts that do not navigate away.
   - Navigating to a different URL (via address bar, link, or shortcut) changes the site shown and is NOT allowed under rule 1. Use rule 2 or 3 first.
2. open_new_tab (key: cmd+t) — only if app_supports_tabs is true. Use this before any URL navigation when a real page is already loaded.
3. open_new_window (key: cmd+n) — only if app_supports_windows is true.
4. activate_app to a different already-running app — the current window stays in the background.
5. action: none with a one-line explanation — only if the task requires replacing the current context and none of 2–4 apply.
Any other action is invalid this turn.
</preserve_semantics>
"""
        return try await agenticLoop(messages: messages, system: system, model: Self.visionModel, screenshotSize: screenshotSize, requireAction: true, onScratchpadUpdate: onScratchpadUpdate)
    }

    // MARK: - Background (headless) task loop

    func runBackgroundTask(
        _ task: String,
        initialMessages: [[String: Any]]? = nil,
        executeTool: @escaping (String, [String: Any]) async throws -> String,
        onStep: @escaping (String) -> Void
    ) async throws -> (summary: String, messages: [[String: Any]]) {
        let system = """
You are a headless macOS automation agent. Complete the given task using only the provided tools.
Think step by step, execute actions, and call complete_task when done.
Browser guidance: prefer background tabs and non-visible page manipulation. Avoid tab churn, focus stealing, and page flashes during intermediate steps. Only surface windows to the user when the task truly requires it — do it late and intentionally, not during every intermediate step.
Screenshot guidance: take_screenshot is expensive — use it sparingly and only when you genuinely need to verify a visual state change (e.g. after clicking something, to confirm a dialog appeared). Never use it as a polling loop. Prefer run_shell or read_app_ui to check state whenever possible.
Claude Code: the `claude` CLI may be available on this system. To use it, first find it with `which claude || find ~ -name claude -type f 2>/dev/null | head -1`, then run it as `<path> -p "your prompt here" --allowedTools "Write,Edit,Bash"` (the flag pre-approves file writes so it never prompts). Useful for delegating coding tasks or having Claude implement something in the current working directory.
Tool installation: you can install missing CLI tools via `brew install <tool>` or `npm install -g <tool>`. If a command is not found, try installing it rather than giving up.
Agent coordination: when you spawn a child agent with start_agent, it runs independently. When a child finishes, it writes a JSON marker to ~/.cue/output/agent_{id}_done.json containing its id, task, summary, and completedAt. The start_agent tool returns the child's id immediately. To wait for a child, poll for its marker file with run_shell: `ls ~/.cue/output/agent_{id}_done.json 2>/dev/null`. To read its result: `cat ~/.cue/output/agent_{id}_done.json`.
"""
        let noInput: [String: Any] = ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
        let tools: [[String: Any]] = [
            ["name": "run_shell",       "description": "Run a shell command via /bin/zsh. Returns stdout and stderr.",                    "input_schema": ["type": "object", "properties": ["command":  ["type": "string"]], "required": ["command"]]  as [String: Any]],
            ["name": "browser_navigate","description": "Navigate the headless browser to a URL.",                                          "input_schema": ["type": "object", "properties": ["url":      ["type": "string"]], "required": ["url"]]      as [String: Any]],
            ["name": "browser_click",   "description": "Click an element in the headless browser by CSS selector.",                        "input_schema": ["type": "object", "properties": ["selector": ["type": "string"]], "required": ["selector"]] as [String: Any]],
            ["name": "browser_type",    "description": "Type text into an element by CSS selector.",                                       "input_schema": ["type": "object", "properties": ["selector": ["type": "string"], "text": ["type": "string"]], "required": ["selector", "text"]] as [String: Any]],
            ["name": "browser_content", "description": "Get current page URL, title, and visible text from the headless browser.",          "input_schema": noInput],
            ["name": "read_app_ui",     "description": "Read the UI element tree of any running macOS app via Accessibility API. Returns buttons, labels, text, values — works on Spotify, Finder, any native app.",
             "input_schema": ["type": "object", "properties": ["app_name": ["type": "string"]], "required": ["app_name"]] as [String: Any]],
            ["name": "take_screenshot",  "description": "Capture the current screen as an image. Use this to see what's on screen — UI state, app windows, dialogs, etc.",  "input_schema": noInput],
            ["name": "complete_task",   "description": "Mark the task as complete. 'summary' is a one-sentence description of what was done. 'output' is the actual content to display to the user — use this when the task asked you to show, list, generate, or produce something (e.g. a list of numbers, a piece of text, search results). Leave 'output' empty for action-only tasks (opening apps, sending messages, etc).",   "input_schema": ["type": "object", "properties": ["summary": ["type": "string"], "output": ["type": "string"]], "required": ["summary"]] as [String: Any]],
            ["name": "start_agent",     "description": "Spawn a sub-agent to complete a well-defined subtask autonomously. Blocks until the sub-agent finishes and returns its summary and output. Use this to delegate parallel work or a self-contained chunk of the overall task.",
             "input_schema": ["type": "object", "properties": ["task": ["type": "string", "description": "Full description of the subtask for the sub-agent to complete."]], "required": ["task"]] as [String: Any]],
        ]

        var messages: [[String: Any]] = initialMessages ?? [["role": "user", "content": "Task: \(task)"]]

        var iteration = 0
        while true {
            iteration += 1
            CueLogger.write("[bg] iteration \(iteration), msgs=\(messages.count)")
            let blocks = try await completeWithTools(
                messages: messages, system: system, maxTokens: 4096,
                model: Self.visionModel, tools: tools, beta: nil, toolChoice: "any"
            )

            var assistantContent: [[String: Any]] = []
            var toolResults: [[String: Any]] = []
            var completeSummary: String? = nil

            for block in blocks {
                assistantContent.append(block)
                guard block["type"] as? String == "tool_use",
                      let id    = block["id"]    as? String,
                      let name  = block["name"]  as? String,
                      let input = block["input"] as? [String: Any] else { continue }

                if name == "complete_task" {
                    let summary = input["summary"] as? String ?? "Done."
                    let output  = input["output"]  as? String ?? ""
                    CueLogger.write("[bg] complete_task: summary=\(summary.prefix(100)) output_len=\(output.count)")
                    let outputThreshold = 400
                    if !output.isEmpty && output.count > outputThreshold {
                        let ts = Int(Date().timeIntervalSince1970)
                        let outputDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cue/output")
                        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                        let fileURL = outputDir.appendingPathComponent("cue_output_\(ts).txt")
                        try? output.write(to: fileURL, atomically: true, encoding: .utf8)
                        NSWorkspace.shared.open(fileURL)
                        CueLogger.write("[bg] output written to \(fileURL.path)")
                        completeSummary = "\(summary)\n\nOutput written to: /tmp/cue_output_\(ts).txt"
                    } else {
                        completeSummary = output.isEmpty ? summary : "\(summary)\n\n\(output)"
                    }
                    toolResults.append(["type": "tool_result", "tool_use_id": id, "content": summary])
                } else if name == "take_screenshot" {
                    onStep("Taking screenshot")
                    CueLogger.write("[bg] → Taking screenshot")
                    do {
                        let (data, _) = try await ScreenCapture.capture()
                        CueLogger.write("[bg] ← screenshot \(data.count) bytes")
                        toolResults.append(["type": "tool_result", "tool_use_id": id, "content": [
                            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
                        ]])
                    } catch {
                        CueLogger.write("[bg] ← screenshot failed: \(error)")
                        toolResults.append(["type": "tool_result", "tool_use_id": id, "content": "Screenshot failed: \(error.localizedDescription)"])
                    }
                } else {
                    let desc = Self.bgStepDescription(name: name, input: input)
                    onStep(desc)
                    CueLogger.write("[bg] → \(desc)")
                    let result: String
                    do { result = try await executeTool(name, input) }
                    catch { result = "Error: \(error.localizedDescription)" }
                    CueLogger.write("[bg] ← \(result.prefix(300))")
                    toolResults.append(["type": "tool_result", "tool_use_id": id, "content": result])
                }
            }

            messages.append(["role": "assistant", "content": assistantContent])
            if let summary = completeSummary {
                messages.append(["role": "user", "content": toolResults])
                return (summary, messages)
            }
            guard !toolResults.isEmpty else {
                CueLogger.write("[bg] no tool results — stopping", level: "WARN")
                break
            }
            messages.append(["role": "user", "content": toolResults])

            // Compress when estimated token count exceeds ~60k tokens (≈240k chars)
            if estimatedChars(messages) > 240_000 {
                let before = estimatedChars(messages)
                messages = try await compressBgHistory(messages, task: task)
                CueLogger.write("[bg] context compressed \(before/1000)k→\(estimatedChars(messages)/1000)k chars, \(messages.count) msgs")
            }
        }
        return ("Stopped after maximum steps.", messages)
    }

    private func estimatedChars(_ messages: [[String: Any]]) -> Int {
        (try? JSONSerialization.data(withJSONObject: messages))?.count ?? 0
    }

    private func compressBgHistory(_ messages: [[String: Any]], task: String) async throws -> [[String: Any]] {
        let keep = 4 // keep last N messages verbatim
        guard messages.count > keep + 1 else { return messages }
        let toCompress = messages.dropFirst().dropLast(keep) // drop task msg + keep tail
        var historyText = ""
        for msg in toCompress {
            let role = msg["role"] as? String ?? "?"
            if let content = msg["content"] as? String {
                historyText += "[\(role)]: \(content.prefix(200))\n"
            } else if let blocks = msg["content"] as? [[String: Any]] {
                let names = blocks.compactMap { $0["name"] as? String }.joined(separator: ", ")
                let texts = blocks.compactMap { $0["content"] as? String }.map { String($0.prefix(100)) }.joined(separator: "; ")
                historyText += "[\(role)]: tools=\(names) \(texts)\n"
            }
        }
        let prompt = "Summarize what this agent has done so far as a tight bullet list (max 12 bullets, each ≤20 words). Focus on: what was tried, what worked, what failed, current state, and what still needs to be done to complete the task. IMPORTANT: always preserve the final goal of the task in your summary.\n\nTask: \(task)\n\nHistory:\n\(historyText)"
        let compressed = try await completeRaw(
            messages: [["role": "user", "content": prompt]],
            system: nil, maxTokens: 400, model: Self.fastModel, tools: nil, beta: nil
        )
        let taskMsg = messages[0]
        let tail = Array(messages.suffix(keep))
        return [taskMsg, ["role": "user", "content": "[Progress summary]\n\(compressed)"]] + tail
    }

    // MARK: - Shared agentic loop

    private func agenticLoop(messages initialMessages: [[String: Any]], system: String, model: String, screenshotSize: CGSize, requireAction: Bool, onScratchpadUpdate: ((String) -> Void)? = nil) async throws -> StepResponse {
        let noInput: [String: Any] = ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
        let infoTools: [[String: Any]] = [
            ["name": "get_running_apps",        "description": "Currently running macOS applications. Call before deciding how to switch to or open an app.", "input_schema": noInput],
            ["name": "get_active_window_title", "description": "Title of the frontmost window (e.g. 'GitHub - Safari').",                                    "input_schema": noInput],
            ["name": "get_browser_url",         "description": "Current URL in the frontmost browser window.",                                               "input_schema": noInput],
            ["name": "get_clipboard",           "description": "Current clipboard text content.",                                                            "input_schema": noInput],
            ["name": "get_selected_text",       "description": "Text currently selected in the frontmost app.",                                              "input_schema": noInput],
            ["name": "get_open_windows",        "description": "All open windows across all apps with their titles.",                                        "input_schema": noInput],
            ["name": "activate_app",            "description": "Bring a running macOS app to the foreground. Use this instead of clicking the Dock or using keyboard shortcuts to switch apps.",
             "input_schema": ["type": "object", "properties": ["app_name": ["type": "string", "description": "The app name exactly as returned by get_running_apps."]], "required": ["app_name"]] as [String: Any]],
            ["name": "update_scratchpad",       "description": "Overwrite your persistent scratchpad with new content. Use this to record observations, state, or notes you'll need in future steps. A compressed summary is injected into every prompt — keep it dense and useful, discard what's no longer needed.",
             "input_schema": ["type": "object", "properties": ["content": ["type": "string", "description": "Full new scratchpad content. Replaces the previous version entirely."]], "required": ["content"]] as [String: Any]],
            ["name": "read_app_ui",             "description": "Read the UI element tree of any running macOS app using the Accessibility API. Returns buttons, labels, text fields, and values — useful for reading app state without a screenshot.",
             "input_schema": ["type": "object", "properties": ["app_name": ["type": "string", "description": "Name of the running app, e.g. 'Spotify', 'Safari', 'Finder'."]], "required": ["app_name"]] as [String: Any]],
            ["name": "web_search",              "description": "Search the web using DuckDuckGo. Returns titles and snippets for the top results. Use this to look up documentation, prices, instructions, or any current information.",
             "input_schema": ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"]], "required": ["query"]] as [String: Any]],
        ]
        let urlSchema: [String: Any] = ["type": "object", "properties": ["url": ["type": "string", "description": "Full URL to navigate to, e.g. https://amazon.com"]], "required": ["url"]]
        let navTools: [[String: Any]] = [
            ["name": "navigate_to_url",          "description": "Navigate the current browser tab to a URL. Use when the current tab is blank or expendable.", "input_schema": urlSchema],
            ["name": "open_tab_and_navigate",    "description": "Open a new browser tab then navigate to a URL. Use when preserve is true and app_supports_tabs is true.", "input_schema": urlSchema],
        ]
        let indicateTool: [String: Any] = [
            "name": "indicate_action",
            "description": requireAction
                ? "Indicate the single next UI action for the user to take."
                : "Point to a specific element on screen. Only call this if the question asks where something is AND target_visible is true.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "target_visible":     ["type": "boolean", "description": "Is the exact intended target clearly and unambiguously visible in the screenshot? Set false if you have any doubt."],
                    "target_description": ["type": "string",  "description": "Describe literally what you see at the coordinate — element, appearance, context. If target_visible is false, describe what's actually there."],
                    "instruction":        ["type": "string",  "description": requireAction ? "Brief instruction for the user (1 sentence)." : "Answer or instruction for the user."],
                    "action":             ["type": "string",  "enum": ["click", "right_click", "scroll", "type", "key", "none"], "description": "MUST NOT be 'click' or 'right_click' if target_visible is false. Use 'none' only when fully complete."],
                    "element_type":       ["type": "string",  "enum": ["text", "link", "field", "button", "icon", "other"]],
                    "element_width":      ["type": "number"],
                    "element_height":     ["type": "number"],
                    "coordinate":         ["type": "array",   "items": ["type": "number"], "description": "[x, y] in screenshot pixels."],
                    "text":               ["type": "string"],
                    "direction":          ["type": "string",  "enum": ["up", "down", "left", "right"]],
                    "amount":             ["type": "integer"],
                    "is_complete":          ["type": "boolean", "description": "True when the overall task is fully done."],
                    "requires_user_input":  ["type": "boolean", "description": "True when you need the user to do something manually (e.g. enter a password, solve a captcha) before the next step can proceed. Cue will pause and wait for them to press Enter."],
                ] as [String: Any],
                "required": ["target_visible", "target_description", "instruction", "action", "is_complete"],
            ] as [String: Any],
        ]

        var messages = initialMessages
        let toolChoice = requireAction ? "any" : "auto"
        let maxIterations = infoTools.count + 4

        for iteration in 0..<maxIterations {
            CueLogger.write("API call (iteration \(iteration)/\(maxIterations), msgs=\(messages.count))")
            let blocks: [[String: Any]]
            do {
                blocks = try await completeWithTools(
                    messages: messages, system: system, maxTokens: requireAction ? 1024 : 400,
                    model: model, tools: infoTools + navTools + [indicateTool], beta: nil, toolChoice: toolChoice
                )
            } catch {
                CueLogger.write("API error: \(error)", level: "ERROR")
                throw error
            }

            let blockSummary = blocks.map { ($0["type"] as? String) ?? "?" }.joined(separator: ", ")
            CueLogger.write("API response blocks: [\(blockSummary)]")

            if blocks.contains(where: { $0["name"] as? String == "indicate_action" }) {
                let result = parseIndicateAction(blocks, screenshotSize: screenshotSize)
                let otherTools = blocks.filter { b in
                    b["type"] as? String == "tool_use" && b["name"] as? String != "indicate_action"
                }
                // If action:none but the model also called other tools, process those and continue.
                if case .none = result.action, !otherTools.isEmpty {
                    CueLogger.write("indicate_action(none) with \(otherTools.count) other tool(s) — processing those first")
                } else {
                    CueLogger.write("Action: \(result.action) | \(result.instruction)")
                    return result
                }
            }

            if let navBlock = blocks.first(where: { ["navigate_to_url", "open_tab_and_navigate"].contains($0["name"] as? String) }),
               let toolName = navBlock["name"] as? String,
               let input = navBlock["input"] as? [String: Any],
               let url = input["url"] as? String {
                let action: StepResponse.ActionType = toolName == "open_tab_and_navigate"
                    ? .openTabAndNavigate(url: url)
                    : .navigate(url: url)
                let instruction = toolName == "open_tab_and_navigate"
                    ? "Opening new tab and navigating to \(url)"
                    : "Navigating to \(url)"
                CueLogger.write("Nav action: \(toolName) → \(url)")
                return StepResponse(instruction: instruction, action: action, isComplete: false)
            }

            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                CueLogger.write("Text response: \(text.prefix(200))")
                return StepResponse(instruction: text, action: .none, isComplete: false)
            }

            var toolResults: [[String: Any]] = []
            var handledAny = false
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let toolID = block["id"] as? String, let toolName = block["name"] as? String else { continue }
                let result: String
                switch toolName {
                case "get_running_apps":        result = SystemInfo.runningApps()
                case "get_active_window_title": result = SystemInfo.activeWindowTitle()
                case "get_browser_url":         result = SystemInfo.browserURL()
                case "get_clipboard":           result = SystemInfo.clipboard()
                case "get_selected_text":       result = SystemInfo.selectedText()
                case "get_open_windows":        result = SystemInfo.openWindows()
                case "activate_app":
                    let input = block["input"] as? [String: Any]
                    let appName = input?["app_name"] as? String ?? ""
                    result = SystemInfo.activateApp(appName)
                case "update_scratchpad":
                    let content = (block["input"] as? [String: Any])?["content"] as? String ?? ""
                    onScratchpadUpdate?(content)
                    result = "Scratchpad updated."
                case "read_app_ui":
                    let appName = (block["input"] as? [String: Any])?["app_name"] as? String ?? ""
                    result = SystemInfo.readAppUI(appName)
                case "web_search":
                    let query = (block["input"] as? [String: Any])?["query"] as? String ?? ""
                    result = (try? await Self.duckDuckGoSearch(query)) ?? "Search failed."
                default:                        result = "unknown tool"
                }
                CueLogger.write("Tool: \(toolName) → \(result.prefix(200))")
                toolResults.append(["type": "tool_result", "tool_use_id": toolID, "content": result])
                handledAny = true
            }
            guard handledAny else {
                CueLogger.write("No tool handled — breaking loop", level: "WARN")
                break
            }
            messages.append(["role": "assistant", "content": blocks])
            messages.append(["role": "user", "content": toolResults])
        }

        CueLogger.write("Loop exhausted without indicate_action", level: "WARN")
        if requireAction { throw LLMError.emptyResponse }
        return StepResponse(instruction: "I'm not sure what to do next. Try rephrasing or press Enter to retry.", action: .none, isComplete: false)
    }

    // MARK: - Private

    /// Returns (textBlocks, toolUseBlocks) from the raw content array.
    private func completeWithTools(
        messages: [[String: Any]],
        system: String?,
        maxTokens: Int,
        model: String,
        tools: [[String: Any]]?,
        beta: String?,
        toolChoice: String = "any"
    ) async throws -> [[String: Any]] {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey }
        guard let base = URL(string: endpoint) else { throw LLMError.invalidEndpoint }
        let url = base.appendingPathComponent("v1/messages")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let system {
            // Wrap in content-block array so we can attach prompt caching.
            body["system"] = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
        }
        if let tools {
            body["tools"] = tools
            body["tool_choice"] = ["type": toolChoice]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        if let beta { req.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decode("non-HTTP response")
        }
        if http.statusCode >= 400 {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.http(status: http.statusCode, body: bodyStr)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]] else {
            throw LLMError.decode("missing content array")
        }

        return contentArr
    }

    private func completeRaw(
        messages: [[String: Any]],
        system: String?,
        maxTokens: Int,
        model: String,
        tools: [[String: Any]]?,
        beta: String?
    ) async throws -> String {
        let blocks = try await completeWithTools(
            messages: messages, system: system, maxTokens: maxTokens, model: model, tools: tools, beta: beta
        )
        let text = blocks
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    private func parseStepResponse(_ blocks: [[String: Any]], screenshotSize: CGSize) -> StepResponse {
        fputs("[cue] parseStepResponse blocks: \(blocks.map { $0["type"] as? String ?? "?" })\n", stderr)

        var instruction = blocks
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .replacingOccurrences(of: "TASK_COMPLETE", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let isComplete = blocks
            .compactMap { $0["text"] as? String }
            .joined()
            .contains("TASK_COMPLETE")

        // Parse tool_use block for action
        let toolBlock = blocks
            .first { $0["type"] as? String == "tool_use" && $0["name"] as? String == "computer" }
        fputs("[cue] tool_use input: \(toolBlock?["input"] as? [String: Any] ?? [:])\n", stderr)
        let action = toolBlock
            .flatMap { parseToolUse($0, screenshotSize: screenshotSize) }
            ?? .none

        // If model returned no text, derive a fallback from the tool input
        if instruction.isEmpty, let input = toolBlock?["input"] as? [String: Any] {
            instruction = describeAction(input)
        }

        return StepResponse(instruction: instruction, action: action, isComplete: isComplete)
    }

    private func parseToolUse(_ block: [String: Any], screenshotSize: CGSize) -> StepResponse.ActionType? {
        guard let input = block["input"] as? [String: Any],
              let actionStr = input["action"] as? String else { return nil }

        // Computer Use coordinates are in screenshot space; convert to screen space
        func toScreen(_ coord: [Any]) -> CGPoint? {
            guard coord.count == 2,
                  let x = coord[0] as? CGFloat,
                  let y = coord[1] as? CGFloat else { return nil }
            guard let screen = NSScreen.main else { return nil }
            let scaleX = screen.frame.width / screenshotSize.width
            let scaleY = screen.frame.height / screenshotSize.height
            // No Y flip — SwiftUI .position() and Computer Use both use top-left origin
            return CGPoint(x: x * scaleX, y: y * scaleY)
        }

        switch actionStr {
        case "left_click", "right_click", "double_click", "middle_click":
            guard let raw = input["coordinate"] as? [Any],
                  let pt = toScreen(raw) else { return nil }
            let elementTypeStr = input["element_type"] as? String ?? "other"
            let elementType = StepResponse.ElementType(rawValue: elementTypeStr) ?? .other
            return .click(x: pt.x, y: pt.y, elementType: elementType, width: 0, height: 0)

        case "scroll":
            guard let raw = input["coordinate"] as? [Any],
                  let pt = toScreen(raw),
                  let dirStr = input["direction"] as? String,
                  let dir = StepResponse.ScrollDirection(rawValue: dirStr) else { return nil }
            let amount = input["amount"] as? Int ?? 3
            return .scroll(x: pt.x, y: pt.y, direction: dir, amount: amount)

        case "type":
            guard let text = input["text"] as? String else { return nil }
            let raw = input["coordinate"] as? [Any]
            let pt = raw.flatMap { toScreen($0) }
            return .type(x: pt?.x ?? 0, y: pt?.y ?? 0, text: text)

        case "key":
            guard let keys = input["text"] as? String else { return nil }
            return .key(keys: keys)

        default:
            return nil
        }
    }

    private func parseIndicateAction(_ blocks: [[String: Any]], screenshotSize: CGSize) -> StepResponse {
        fputs("[cue] parseIndicateAction blocks: \(blocks.map { $0["type"] as? String ?? "?" })\n", stderr)
        guard let block = blocks.first(where: { $0["name"] as? String == "indicate_action" }),
              let input = block["input"] as? [String: Any] else {
            // Fallback: try parsing as plain Computer Use output.
            return parseStepResponse(blocks, screenshotSize: screenshotSize)
        }
        fputs("[cue] indicate_action input: \(input)\n", stderr)

        let instruction = (input["instruction"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isComplete = input["is_complete"] as? Bool ?? false
        let targetVisible = input["target_visible"] as? Bool ?? true
        var actionStr = input["action"] as? String ?? "none"

        // Enforce visibility constraint: if model said target isn't visible, don't click it.
        if !targetVisible && actionStr == "click" {
            fputs("[cue] target_visible=false but action=click — overriding to scroll up\n", stderr)
            actionStr = "scroll"
        }

        guard let screen = NSScreen.main else {
            return StepResponse(instruction: instruction, action: .none, isComplete: isComplete)
        }
        let scaleX = screen.frame.width / screenshotSize.width
        let scaleY = screen.frame.height / screenshotSize.height

        func toScreen(_ raw: Any?) -> CGPoint? {
            guard let arr = raw as? [Any], arr.count == 2,
                  let x = (arr[0] as? NSNumber)?.doubleValue,
                  let y = (arr[1] as? NSNumber)?.doubleValue else { return nil }
            return CGPoint(x: CGFloat(x) * scaleX, y: CGFloat(y) * scaleY)
        }

        let elementType = StepResponse.ElementType(rawValue: input["element_type"] as? String ?? "") ?? .other
        let elemW = (input["element_width"]  as? NSNumber).map { CGFloat($0.doubleValue) * scaleX } ?? 0
        let elemH = (input["element_height"] as? NSNumber).map { CGFloat($0.doubleValue) * scaleY } ?? 0

        let screenCenter = CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)

        let action: StepResponse.ActionType
        switch actionStr {
        case "click":
            let pt = toScreen(input["coordinate"]) ?? screenCenter
            action = .click(x: pt.x, y: pt.y, elementType: elementType, width: elemW, height: elemH)
        case "right_click":
            let pt = toScreen(input["coordinate"]) ?? screenCenter
            action = .rightClick(x: pt.x, y: pt.y, elementType: elementType, width: elemW, height: elemH)
        case "scroll":
            let pt = toScreen(input["coordinate"]) ?? screenCenter
            let dirStr = input["direction"] as? String ?? "down"
            let dir = StepResponse.ScrollDirection(rawValue: dirStr) ?? .down
            let amount = (input["amount"] as? NSNumber)?.intValue ?? 3
            action = .scroll(x: pt.x, y: pt.y, direction: dir, amount: amount)
        case "type":
            let pt = toScreen(input["coordinate"])
            action = .type(x: pt?.x ?? 0, y: pt?.y ?? 0, text: input["text"] as? String ?? "")
        case "key":
            action = .key(keys: input["text"] as? String ?? "")
        default:
            action = .none
        }

        let targetDesc = input["target_description"] as? String ?? ""
        let requiresUserInput = input["requires_user_input"] as? Bool ?? false
        var response = StepResponse(instruction: instruction, action: action, isComplete: isComplete)
        response.targetDescription = targetDesc
        response.requiresUserInput = requiresUserInput
        return response
    }

    private static func duckDuckGoSearch(_ query: String) async throws -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)") else {
            return "Invalid query."
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return "Could not decode response." }
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 20 && !$0.hasPrefix("JavaScript") && !$0.hasPrefix("DuckDuckGo") }
        let results = lines.prefix(25).joined(separator: "\n")
        return results.isEmpty ? "No results found." : results
    }

    private func describeAction(_ input: [String: Any]) -> String {
        guard let actionStr = input["action"] as? String else { return "" }
        switch actionStr {
        case "left_click", "right_click", "double_click": return "Click the highlighted element."
        case "scroll": return "Scroll \(input["direction"] as? String ?? "down")."
        case "type": return "Type: \(input["text"] as? String ?? "")"
        case "key": return "Press \(input["text"] as? String ?? "")"
        default: return ""
        }
    }
}
