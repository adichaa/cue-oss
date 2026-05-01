import Foundation

struct TaskRecord: Codable {
    let id: String
    let task: String
    let completedAt: Date
    let steps: [String]
}

enum TaskHistory {
    private static let fileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".cue/history.json")

    static func save(_ record: TaskRecord) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var records = load()
        records.append(record)
        if records.count > 100 { records = Array(records.suffix(100)) }
        try? JSONEncoder().encode(records).write(to: fileURL)
    }

    static func load() -> [TaskRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TaskRecord].self, from: data)) ?? []
    }
}
