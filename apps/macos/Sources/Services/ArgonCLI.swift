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
        // ARGON_CLI env var
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

        // Fallback: assume on PATH
        return "argon"
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
