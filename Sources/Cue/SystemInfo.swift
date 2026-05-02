import AppKit
import ApplicationServices

struct SystemInfo {
    static func runningApps() -> String {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ", ")
    }

    static func activeWindowTitle() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        return windowTitle(pid: app.processIdentifier) ?? "unknown"
    }

    static func browserURL() -> String {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let safariNames = ["Safari", "Safari Technology Preview"]
        let chromeNames = ["Google Chrome", "Arc", "Brave Browser", "Microsoft Edge", "Opera", "Chromium"]

        if let app = running.first(where: { safariNames.contains($0.localizedName ?? "") }) {
            let script = "tell application \"\(app.localizedName!)\" to return URL of current tab of front window"
            let url = appleScript(script)
            if !url.isEmpty && url.hasPrefix("http") { return "\(url) — tab has existing content, open a new tab (cmd+t) before navigating away" }
        }
        if let app = running.first(where: { chromeNames.contains($0.localizedName ?? "") }) {
            let script = "tell application \"\(app.localizedName!)\" to return URL of active tab of front window"
            let url = appleScript(script)
            if !url.isEmpty && url.hasPrefix("http") { return "\(url) — tab has existing content, open a new tab (cmd+t) before navigating away" }
        }
        return "URL unavailable"
    }

    static func clipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? "clipboard is empty or contains non-text content"
    }

    static func selectedText() -> String {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              focusedRef != nil, CFGetTypeID(focusedRef!) == AXUIElementGetTypeID() else { return "no text selected" }
        let focused = focusedRef as! AXUIElement
        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String, !text.isEmpty else { return "no text selected" }
        return text
    }

    @discardableResult
    static func activateApp(_ name: String) -> String {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let target = apps.first { ($0.localizedName ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { ($0.localizedName ?? "").localizedCaseInsensitiveContains(name) }
        guard let app = target else { return "App '\(name)' not found in running apps" }
        let result = shell("/usr/bin/open", args: ["-a", app.localizedName ?? name])
        return result.isEmpty ? "Activated \(app.localizedName ?? name)" : result
    }

    static func openWindows() -> String {
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            for window in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, !title.isEmpty {
                    lines.append("\(name): \(title)")
                }
            }
        }
        return lines.isEmpty ? "no windows found" : lines.joined(separator: "\n")
    }

    static func currentContextBlock() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else { return "" }
        let bundleID = app.bundleIdentifier ?? ""
        let title = windowTitle(pid: app.processIdentifier) ?? name
        let (tabs, windows) = appCapabilities(bundleID: bundleID)
        let browserBundleIDs: Set<String> = [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview",
            "com.google.Chrome", "company.thebrowser.Browser",
            "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        ]
        let preserve: Bool
        if browserBundleIDs.contains(bundleID) {
            preserve = browserURL().hasPrefix("http")
        } else {
            preserve = true
        }
        return """
        <current_context>
        active_app: \(name)
        window_title: \(title)
        app_supports_tabs: \(tabs)
        app_supports_windows: \(windows)
        preserve: \(preserve)
        </current_context>
        """
    }

    private static func appCapabilities(bundleID: String) -> (tabs: Bool, windows: Bool) {
        switch bundleID {
        case "com.apple.Safari",
             "com.apple.SafariTechnologyPreview":          return (tabs: true,  windows: true)
        case "com.google.Chrome",
             "company.thebrowser.Browser",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "org.mozilla.firefox":                        return (tabs: true,  windows: true)
        case "com.microsoft.VSCode",
             "com.todesktop.230313mzl4w4u92":              return (tabs: true,  windows: true)
        case "com.apple.Terminal",
             "com.googlecode.iterm2":                      return (tabs: true,  windows: true)
        case "com.tinyspeck.slackmacgap":                 return (tabs: false, windows: false)
        case "com.apple.finder":                           return (tabs: false, windows: true)
        case "com.apple.Preview":                          return (tabs: false, windows: true)
        case "com.apple.mail":                             return (tabs: false, windows: true)
        default:                                           return (tabs: false, windows: true)
        }
    }

    // MARK: - AX UI reader

    static func readAppUI(_ appName: String) -> String {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
        guard let app = apps.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName) }) else {
            return "App '\(appName)' is not running."
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return "No windows found for '\(appName)'."
        }

        var lines: [String] = ["App: \(app.localizedName ?? appName)"]
        var count = 0
        for (i, window) in windows.prefix(3).enumerated() {
            var titleRef: CFTypeRef?
            let title = (AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success)
                ? (titleRef as? String ?? "Window \(i+1)") : "Window \(i+1)"
            lines.append("Window: \(title)")
            traverseAX(element: window, depth: 0, maxDepth: 6, lines: &lines, count: &count, max: 120)
        }
        return lines.joined(separator: "\n")
    }

    private static func traverseAX(element: AXUIElement, depth: Int, maxDepth: Int, lines: inout [String], count: inout Int, max: Int) {
        guard depth < maxDepth, count < max else { return }

        var roleRef: CFTypeRef?
        var labelRef: CFTypeRef?
        var valueRef: CFTypeRef?
        var titleRef: CFTypeRef?

        let role  = (AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,        &roleRef)  == .success) ? (roleRef  as? String ?? "") : ""
        let label = (AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString,  &labelRef) == .success) ? (labelRef as? String ?? "") : ""
        let value = (AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,        &valueRef) == .success) ? "\(valueRef!)" : ""
        let title = (AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString,        &titleRef) == .success) ? (titleRef  as? String ?? "") : ""

        let indent = String(repeating: "  ", count: depth)
        let parts  = [role, title, label, value].filter { !$0.isEmpty && $0 != role }
        let text   = parts.prefix(2).joined(separator: ": ")

        let skip = ["AXScrollArea", "AXGroup", "AXSplitGroup", "AXScrollBar", "AXGrowArea", "AXUnknown", "AXWindow", "AXApplication"]
        if !role.isEmpty && !skip.contains(role) {
            let line = text.isEmpty ? "\(indent)\(role)" : "\(indent)\(role): \(text.prefix(80))"
            lines.append(line)
            count += 1
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            traverseAX(element: child, depth: depth + 1, maxDepth: maxDepth, lines: &lines, count: &count, max: max)
        }
    }

    // MARK: - Private helpers

    @discardableResult
    private static func shell(_ path: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func appleScript(_ source: String) -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue ?? ""
    }

    private static func windowTitle(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              windowRef != nil, CFGetTypeID(windowRef!) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }

}
