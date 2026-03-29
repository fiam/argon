import Foundation

enum ArgonCLI {
    static func addDraftComment(
        sessionId: String, repoRoot: String, message: String,
        filePath: String? = nil, lineNew: UInt32? = nil, lineOld: UInt32? = nil,
        threadId: String? = nil
    ) throws {
        var args = [
            "draft", "add",
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

    static func deleteDraftComment(
        sessionId: String, repoRoot: String, draftId: String
    ) throws {
        try run(repoRoot: repoRoot, args: [
            "draft", "delete",
            "--session", sessionId,
            "--draft-id", draftId,
            "--json",
        ])
    }

    static func submitReview(
        sessionId: String, repoRoot: String, outcome: String?, summary: String?
    ) throws {
        var args = [
            "draft", "submit",
            "--session", sessionId,
            "--json",
        ]
        if let outcome {
            args.append(contentsOf: ["--outcome", outcome])
        }
        if let summary {
            args.append(contentsOf: ["--summary", summary])
        }
        try run(repoRoot: repoRoot, args: args)
    }

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
        if let cli = ProcessInfo.processInfo.environment["ARGON_CLI_CMD"], !cli.isEmpty {
            let trimmed = cli.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if FileManager.default.fileExists(atPath: trimmed) {
                return trimmed
            }
        }

        if let cli = ProcessInfo.processInfo.environment["ARGON_CLI"], !cli.isEmpty {
            return cli
        }

        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin/argon").path,
           FileManager.default.fileExists(atPath: bundlePath)
        {
            return bundlePath
        }

        for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
            let path = "\(dir)/argon"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

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
