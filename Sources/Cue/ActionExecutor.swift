import CoreGraphics
import AppKit

enum ActionExecutor {
    static func execute(_ action: StepResponse.ActionType, targetPid: pid_t? = nil) async {
        switch action {
        case .click(let x, let y, _, _, _):
            click(at: CGPoint(x: x, y: y))
        case .rightClick(let x, let y, _, _, _):
            rightClick(at: CGPoint(x: x, y: y))
        case .scroll(let x, let y, let direction, let amount):
            scroll(at: CGPoint(x: x, y: y), direction: direction, amount: amount)
        case .type(_, _, let text):
            type(text, pid: targetPid)
        case .key(let keys):
            key(keys, pid: targetPid)
        case .navigate, .openTabAndNavigate:
            break // handled in AppDelegate
        case .shell(let command):
            await runShell(command)
        case .none:
            break
        }
    }

    private static func click(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up   = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func rightClick(at point: CGPoint) {
        // Fire down+up immediately so mouseUp lands before the context menu renders.
        // Delaying mouseUp causes it to land on a menu item that appeared under the cursor.
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)
        let up   = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,   mouseCursorPosition: point, mouseButton: .right)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func scroll(at point: CGPoint, direction: StepResponse.ScrollDirection, amount: Int) {
        let lines = Int32(amount)
        let wheel1: Int32
        let wheel2: Int32
        switch direction {
        case .up:    wheel1 = lines;  wheel2 = 0
        case .down:  wheel1 = -lines; wheel2 = 0
        case .left:  wheel1 = 0;      wheel2 = lines
        case .right: wheel1 = 0;      wheel2 = -lines
        }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }

    private static func type(_ text: String, pid: pid_t?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        key("cmd+v", pid: pid)
    }

    private static func key(_ combo: String, pid: pid_t?) {
        let parts = combo.lowercased().components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode = 0
        var foundKey = false

        for part in parts {
            switch part {
            case "cmd", "command":          flags.insert(.maskCommand)
            case "shift":                   flags.insert(.maskShift)
            case "opt", "option", "alt":    flags.insert(.maskAlternate)
            case "ctrl", "control":         flags.insert(.maskControl)
            default:
                if let kc = keyCodes[part] { keyCode = kc; foundKey = true }
            }
        }
        guard foundKey else { return }

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags

        if let pid {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    @discardableResult
    private static func runShell(_ command: String) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-c", command]
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError  = errPipe
                try? proc.run()
                proc.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: combined.isEmpty ? "(exit \(proc.terminationStatus))" : combined)
            }
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
