import Foundation

actor PlaywrightSidecar {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pendingContinuations: [CheckedContinuation<[String: Any], Error>] = []
    private var buffer = Data()
    private var started = false

    func start() throws {
        guard !started else { return }
        let node = try findNode()
        let script = try sidecarScriptPath()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = [script]

        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = FileHandle.nullDevice

        try proc.run()
        // put in its own process group so stop() can kill the whole tree (node + chromium)
        setpgid(proc.processIdentifier, proc.processIdentifier)
        process     = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        started     = true

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            Task { await self?.received(data) }
        }
    }

    func send(_ command: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              let line = String(data: data, encoding: .utf8) else {
            throw SidecarError.encodingFailed
        }
        stdinHandle?.write((line + "\n").data(using: .utf8) ?? Data())
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.appendContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SidecarError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func appendContinuation(_ cont: CheckedContinuation<[String: Any], Error>) {
        pendingContinuations.append(cont)
    }

    var processGroupID: pid_t? { process?.processIdentifier }

    func stop() {
        stdinHandle?.closeFile()
        if let pid = process?.processIdentifier {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3)
            while process?.isRunning == true && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            kill(-pid, SIGKILL)
        }
        process     = nil
        stdinHandle = nil
        started     = false
        for cont in pendingContinuations { cont.resume(throwing: SidecarError.stopped) }
        pendingContinuations.removeAll()
    }

    private func received(_ data: Data) {
        buffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer = Data(buffer[buffer.index(after: idx)...])
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  !pendingContinuations.isEmpty else { continue }
            let cont = pendingContinuations.removeFirst()
            if let msg = json["error"] as? String {
                cont.resume(throwing: SidecarError.remote(msg))
            } else {
                cont.resume(returning: json)
            }
        }
    }

    private func findNode() throws -> String {
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Try `which node` via a login shell so nvm/asdf paths are on PATH
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "which node"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !found.isEmpty { return found }
        throw SidecarError.nodeNotFound
    }

    private func sidecarScriptPath() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            Bundle.main.bundlePath + "/sidecar.js",
            (Bundle.main.resourcePath ?? "") + "/sidecar.js",
            home + "/Desktop/cue/sidecar/index.js",
            "./sidecar/index.js",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) { return path }
        throw SidecarError.scriptNotFound
    }

    enum SidecarError: LocalizedError {
        case nodeNotFound, scriptNotFound, encodingFailed, stopped, timeout
        case remote(String)
        var errorDescription: String? {
            switch self {
            case .nodeNotFound:   return "Node.js not found — run: brew install node && npx playwright install chromium"
            case .scriptNotFound: return "Playwright sidecar script not found"
            case .encodingFailed: return "Failed to encode sidecar command"
            case .stopped:        return "Sidecar was stopped"
            case .timeout:        return "Sidecar command timed out"
            case .remote(let m):  return "Sidecar: \(m)"
            }
        }
    }
}
