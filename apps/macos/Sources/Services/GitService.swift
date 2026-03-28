import Foundation

enum GitService {
    static func diff(session: ReviewSession) -> String {
        let repoRoot = session.repoRoot
        var args = ["-C", repoRoot, "diff", "--no-color", "--unified=3", "--no-ext-diff"]

        switch session.mode {
        case .branch:
            args.append(session.mergeBaseSha)
            // Include working tree changes if the head ref is checked out
            if let currentHead = resolveRef(repoRoot: repoRoot, ref: "HEAD"),
               let targetHead = resolveRef(repoRoot: repoRoot, ref: session.headRef),
               currentHead != targetHead
            {
                args.append(session.headRef)
            }
        case .commit:
            args.append(session.baseRef)
        case .uncommitted:
            args.append("HEAD")
        }

        return runGit(args)
    }

    private static func resolveRef(repoRoot: String, ref: String) -> String? {
        let output = runGit(["-C", repoRoot, "rev-parse", "--verify", "\(ref)^{commit}"])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func runGit(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
