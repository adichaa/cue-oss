import Foundation

enum PolicyAction: String {
    case allow, ask, deny
}

@MainActor
final class PolicyEngine {
    static let shared = PolicyEngine()

    private let cueDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cue")

    private init() {
        createDefaultsIfNeeded()
    }

    // MARK: - Public

    func resolve(action: StepResponse.ActionType, app: String) -> PolicyAction {
        if case .none = action { return .allow }
        if case .scroll = action { return .allow }
        let merged = mergedPolicy(for: app)
        return merged.value(for: action)
    }

    func writeAllow(app: String, action: StepResponse.ActionType) {
        let key = actionKey(action)
        guard !key.isEmpty else { return }
        ensureAppFile(for: app)
        let fileURL = appFileURL(for: app)
        var dict = loadDict(from: fileURL) ?? [:]
        dict[key] = "allow"
        write(dict, to: fileURL)
    }

    /// Creates a default app yaml the first time Cue interacts with an app.
    func ensureAppFile(for app: String) {
        let fileURL = appFileURL(for: app)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = """
        # Cue policy for \(app) — values: allow | ask | deny
        # Inherits global defaults from ~/.cue/settings.yaml
        """
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Resolution

    private func mergedPolicy(for app: String) -> RawPolicy {
        let global = loadDict(from: cueDir.appendingPathComponent("settings.yaml"))
        let perApp = loadDict(from: appFileURL(for: app))
        return RawPolicy(base: global, override: perApp)
    }

    // MARK: - File I/O

    private func appFileURL(for app: String) -> URL {
        let name = app.lowercased().replacingOccurrences(of: " ", with: "-")
        return cueDir.appendingPathComponent("apps/\(name).yaml")
    }

    private func loadDict(from url: URL) -> [String: String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.isEmpty, !t.hasPrefix("-") else { continue }
            let parts = t.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            let v = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !v.isEmpty { result[k] = v }
        }
        return result.isEmpty ? nil : result
    }

    private func write(_ dict: [String: String], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = dict.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createDefaultsIfNeeded() {
        try? FileManager.default.createDirectory(at: cueDir.appendingPathComponent("apps"), withIntermediateDirectories: true)
        let settingsURL = cueDir.appendingPathComponent("settings.yaml")
        guard !FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let defaults = """
        # Cue global policy — values: allow | ask | deny
        click: ask
        right_click: ask
        key: allow
        navigate: allow
        open_tab_and_navigate: allow
        scroll: allow
        type: allow
        """
        try? defaults.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    private func actionKey(_ action: StepResponse.ActionType) -> String {
        switch action {
        case .click:              return "click"
        case .rightClick:         return "right_click"
        case .type:               return "type"
        case .key:                return "key"
        case .navigate:           return "navigate"
        case .openTabAndNavigate: return "open_tab_and_navigate"
        case .scroll:             return "scroll"
        case .shell:              return "shell"
        case .none:               return ""
        }
    }
}

// MARK: - RawPolicy

private struct RawPolicy {
    let click:              PolicyAction
    let rightClick:         PolicyAction
    let type:               PolicyAction
    let key:                PolicyAction
    let navigate:           PolicyAction
    let openTabAndNavigate: PolicyAction
    let scroll:             PolicyAction

    init(base: [String: String]?, override: [String: String]?) {
        func resolve(_ key: String) -> PolicyAction {
            if let v = override?[key], let p = PolicyAction(rawValue: v) { return p }
            if let v = base?[key],     let p = PolicyAction(rawValue: v) { return p }
            return Self.hardcodedDefault(for: key)
        }
        self.click              = resolve("click")
        self.rightClick         = resolve("right_click")
        self.type               = resolve("type")
        self.key                = resolve("key")
        self.navigate           = resolve("navigate")
        self.openTabAndNavigate = resolve("open_tab_and_navigate")
        self.scroll             = resolve("scroll")
    }

    func value(for action: StepResponse.ActionType) -> PolicyAction {
        switch action {
        case .click:              return click
        case .rightClick:         return rightClick
        case .type:               return type
        case .key:                return key
        case .navigate:           return navigate
        case .openTabAndNavigate: return openTabAndNavigate
        case .scroll:             return scroll
        case .shell:              return .allow
        case .none:               return .allow
        }
    }

    private static func hardcodedDefault(for key: String) -> PolicyAction {
        switch key {
        case "click", "right_click": return .ask
        default:                     return .allow
        }
    }
}
