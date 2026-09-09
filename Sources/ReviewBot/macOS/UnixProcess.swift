import Foundation

/// How macOS starts a command: through `/usr/bin/env` under a `perl alarm`, so the time limit
/// is enforced by the kernel's `SIGALRM` rather than by anything this process has to stay alive
/// to do. This is the launcher `ProcessRunner` uses on macOS; `WindowsProcess.swift` is the
/// other one.
enum PlatformProcess: PlatformProcessLaunching {
    /// A Finder- or launch-at-login-started app inherits launchd's minimal environment (often
    /// just `/usr/bin:/bin:/usr/sbin:/sbin`), so CLIs installed by a version manager (nvm, mise,
    /// volta, fnm, asdf) are unreachable. We ask the login+interactive shell for its real `PATH`
    /// once, then fall back to a fixed list of common install dirs and the inherited value.
    static let augmentedPATH: String = ProcessRunner.composePATH(
        shellPath: loginShellPATH(),
        inherited: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        home: FileManager.default.homeDirectoryForCurrentUser.path
    )

    static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        stdout: URL,
        stderr: URL,
        timeout: Int
    ) throws -> LaunchOutcome {
        let fileManager = FileManager.default
        _ = fileManager.createFile(atPath: stdout.path, contents: nil)
        _ = fileManager.createFile(atPath: stderr.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdout)
        let stderrHandle = try FileHandle(forWritingTo: stderr)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "alarm shift @ARGV; exec @ARGV or exit 127",
            String(timeout),
            "/usr/bin/env",
            executable,
        ] + arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice
        process.environment = environment

        try process.run()
        process.waitUntilExit()
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let timedOut = process.terminationReason == .uncaughtSignal
            && process.terminationStatus == SIGALRM
        return LaunchOutcome(exitCode: process.terminationStatus, timedOut: timedOut)
    }

    /// The first directory on the augmented `PATH` holding an executable file of that name.
    static func locate(_ command: String) -> String? {
        guard !command.contains("/") else {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for directory in augmentedPATH.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Asks the user's login+interactive shell for its `PATH`, or `nil` if the probe fails.
    /// Uses `-i -l` so rc files that initialise version managers (commonly `~/.zshrc`) are sourced,
    /// wraps the shell in the same `perl alarm` timeout used for reviews so a hanging rc file can't
    /// stall startup, and emits the value behind a sentinel so a chatty rc banner can't corrupt it.
    private static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let sentinel = "__REVIEWBOT_PATH__:"
        let script = "printf '%s%s\\n' '\(sentinel)' \"$PATH\""
        guard let output = captureStdout(
            "/usr/bin/perl",
            arguments: [
                "-e", "alarm shift @ARGV; exec @ARGV or exit 127",
                "5",
                shell, "-ilc", script,
            ]
        ) else {
            return nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix(sentinel) {
            let value = line.dropFirst(sentinel.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Runs a process to completion and returns its stdout, or `nil` on any failure. Reads stdout
    /// from a temp file (not a pipe) so a large rc banner can't deadlock, and discards stderr.
    private static func captureStdout(_ launchPath: String, arguments: [String]) -> String? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("review-bot-path-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? fm.removeItem(at: directory) }

        let stdoutURL = directory.appendingPathComponent("stdout")
        fm.createFile(atPath: stdoutURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: stdoutURL) else { return nil }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        try? handle.synchronize()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
    }
}
