import os
import Foundation

enum CueLogger {
    private static let subsystem = "com.cue"
    static let api    = Logger(subsystem: subsystem, category: "api")
    static let task   = Logger(subsystem: subsystem, category: "task")
    static let action = Logger(subsystem: subsystem, category: "action")

    private static var fileHandle: FileHandle?
    private static let queue = DispatchQueue(label: "com.cue.logger")

    static func setup() {
        queue.async {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cue/logs")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let file = dir.appendingPathComponent("\(fmt.string(from: Date())).log")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: file)
            write("=== Cue session started ===")
        }
    }

    static func write(_ message: String, level: String = "INFO") {
        queue.async {
            let line = "[\(timestamp())] [\(level)] \(message)\n"
            fileHandle?.write(line.data(using: .utf8) ?? Data())
        }
        fputs("[\(level)] \(message)\n", stderr)
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: Date())
    }
}
