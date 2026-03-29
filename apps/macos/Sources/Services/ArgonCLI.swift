import Foundation

enum ArgonCLI {
    static func setDecision(
        sessionId: String, repoRoot: String, outcome: String, summary: String?
    ) throws {
        var args = [
            "agent", "dev", "decide",
            "--session", sessionId,
            "--outcome", outcome,
            "--json",
        ]
        if let summary {
            args.append(contentsOf: ["--summary", summary])
        }
        try run(repoRoot: repoRoot, args: args)
    }

    static func addComment(
        sessionId: String, repoRoot: String, message: String,
        filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil,
        threadId: String? = nil
    ) throws {
        var args = [
            "agent", "dev", "comment",
            "--session", sessionId,
            "--message", message,
            "--json",
        ]
        if let threadId {
            args.append(contentsOf: ["--thread", threadId])
        }
        if let filePath {
            args.append(contentsOf: ["--file", filePath])
        }
        if let lineNew {
            args.append(contentsOf: ["--line-new", String(lineNew)])
        }
        if let lineOld {
            args.append(contentsOf: ["--line-old", String(lineOld)])
        }
        try run(repoRoot: repoRoot, args: args)
    }

    static func closeSession(sessionId: String, repoRoot: String) throws {
        try run(repoRoot: repoRoot, args: [
            "agent", "close",
            "--session", sessionId,
            "--json",
        ])
    }

    @discardableResult
    private static func run(repoRoot: String, args: [String]) throws -> String {
        let cli = findCLI()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["--repo", repoRoot] + args
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        if process.terminationStatus != 0 {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown error"
            throw CLIError.commandFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }

    private static func findCLI() -> String {
        // ARGON_CLI_CMD (set by the argon CLI when it launches the app)
        if let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"], !cli.isEmpty {
            // Strip surrounding quotes if present
            let trimmed = cli.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if FileManager.default.fileExists(atPath: trimmed) {
                return trimmed
            }
        }

        // ARGON_CLI env var (explicit override)
        if let cli = ProcessInfo.processInfo.environment["ARGON_CLI"], !cli.isEmpty {
            return cli
        }

        // Bundled CLI in .app
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/argon").path,
           FileManager.default.fileExists(atPath: bundlePath)
        {
            return bundlePath
        }

        // Try to find argon on PATH by checking common locations
        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            let path = "\(dir)/argon"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Last resort
        return "/usr/local/bin/argon"
    }

    enum CLIError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let msg): msg
            }
        }
    }
}
