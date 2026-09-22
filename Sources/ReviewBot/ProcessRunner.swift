import Foundation

struct CommandResult {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// Review Bot ended the command itself because its output matched the caller's
    /// `stopEarly` watch — see `OutputWatch`. Never `succeeded`.
    var stoppedEarly = false

    var succeeded: Bool { exitCode == 0 && !stoppedEarly }
}

/// Called with each line a command writes (stdout and stderr alike) while it runs. Returning
/// `true` ends the command at once, and that line becomes the tail of the result's `stderr`.
///
/// This exists because a CLI can learn it will never finish and still not exit: opencode, told
/// its usage limit is exceeded, logs the error and then sits until the time limit kills it —
/// fifteen minutes per review, every review, with nothing on its streams to say why. The watch
/// lets the caller name what "never finishing" looks like and stop paying for it.
typealias OutputWatch = @Sendable (String) -> Bool

/// Changes applied on top of the inherited environment. A `nil` value removes the variable,
/// which is how a reviewer configured for session auth is kept from silently picking up an
/// API key that happens to be exported in the developer's shell.
typealias EnvironmentOverrides = [String: String?]

protocol CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult

    /// Runs a command with per-command changes applied to the process environment. A `nil`
    /// value removes the variable (see `EnvironmentOverrides`), which is how a reviewer
    /// configured for session auth is kept from inheriting an exported API key. A default
    /// implementation is provided in an extension, so mocks that only implement the
    /// environment-free variant keep working.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult

    /// As above, with an `OutputWatch` that can end the command before its time limit. The
    /// default implementation in the extension ignores the watch — so a wrapper such as
    /// `AccountScopedRunner` must forward this overload explicitly, or the watch is dropped
    /// silently and a stuck reviewer waits out its whole limit again.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        stopEarly: OutputWatch?,
        timeout: Int
    ) async throws -> CommandResult
}

extension CommandRunning {
    func run(
        _ executable: String,
        arguments: [String],
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: nil,
            timeout: timeout
        )
    }

    /// Runners that do not care about the environment (test doubles, mainly) inherit this and
    /// behave exactly as they did before environment overrides existed.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
    }

    /// Runners with no way to watch output (test doubles, wrappers written before the watch
    /// existed) inherit this: the command runs to completion or its limit, as before.
    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        stopEarly: OutputWatch?,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            timeout: timeout
        )
    }
}

enum CommandExecutionError: LocalizedError {
    /// `detail` is the last line the command wrote before the limit fired, when there was one:
    /// a CLI that printed why it was stuck and then hung leaves that reason in the failure.
    case timedOut(command: String, seconds: Int, detail: String? = nil)
    /// The command names nothing that can be started: not on `PATH`, or on `PATH` only as a
    /// launcher this app refuses to run through a shell (see `NpmShim`).
    case notFound(command: String, detail: String)
    /// The OS refused to start the process at all.
    case launchFailed(command: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, seconds, detail):
            "Command timed out after \(seconds) seconds: \(command)"
                + (detail.map { " — \($0)" } ?? "")
        case let .notFound(command, detail):
            "Command not found: \(command) — \(detail)"
        case let .launchFailed(command, detail):
            "Could not start \(command): \(detail)"
        }
    }
}

/// What one platform's launcher reports back: the exit status, or that the time limit fired.
struct LaunchOutcome {
    var exitCode: Int32
    var timedOut: Bool
    /// The launcher ended the process because `stopWhen` said to.
    var stoppedEarly = false
    /// Anything the launcher knows about an abnormal end that the exit code alone hides — a
    /// Windows exception status, say. Surfaced in place of an empty stderr, so a process that
    /// died without a word still leaves a diagnosis in the log.
    var detail: String? = nil
}

/// The pieces of process launching that differ between macOS and Windows. Each platform
/// folder provides `PlatformProcess` with exactly these members; the core never touches an
/// OS API for processes itself.
///
/// - `augmentedPATH` — the `PATH` every child inherits. On macOS the login shell is probed for
///   the real one, since a Finder-launched app starts with launchd's; on Windows the user's
///   `Path` is already complete, and common installer directories are appended.
/// - `launch` — starts `executable` under a hard time limit and waits for it. The core
///   passes an already-composed environment and the files the output streams go to, so the
///   launcher's only job is the OS-specific part: how the limit is enforced (`perl alarm` on
///   macOS, a job object on Windows), how the command is resolved (`env` on macOS, a
///   `PATH`/`PATHEXT` search plus npm shim unwrapping on Windows), and how the child's
///   standard handles are wired to those files. While it waits it asks `stopWhen` about once
///   a second and ends the process — as it would on the time limit — when that returns true.
/// - `locate` — where `command` would resolve to, or `nil`, for the tool-availability panel.
protocol PlatformProcessLaunching {
    static var augmentedPATH: String { get }
    static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        stdout: URL,
        stderr: URL,
        timeout: Int,
        stopWhen: (() -> Bool)?
    ) throws -> LaunchOutcome
    static func locate(_ command: String) -> String?
}

struct ProcessRunner: CommandRunning {
    private let fileManager = FileManager.default

    /// The `PATH` every spawned command inherits. See `PlatformProcessLaunching.augmentedPATH`
    /// for what each platform does to recover it. Computed lazily, exactly once.
    static let augmentedPath: String = PlatformProcess.augmentedPATH

    /// The platform's list separator inside `PATH`: `:` on macOS, `;` on Windows.
    static var pathListSeparator: String {
        #if os(Windows)
        ";"
        #else
        ":"
        #endif
    }

    /// Merges the login-shell `PATH` (if any), a fixed list of common install directories, and
    /// the inherited `PATH` into a single ordered, de-duplicated `PATH`. Pure so it can be tested
    /// without spawning a shell. This is the Unix shape — colon-separated, Homebrew and the
    /// npm-global prefix — and the one the macOS launcher uses; `WindowsCommandResolution`
    /// carries the Windows equivalent.
    static func composePATH(shellPath: String?, inherited: String, home: String) -> String {
        let preferredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ]
        let ordered = (shellPath.map { [$0] } ?? []) + preferredPaths + [inherited]
        var seen = Set<String>()
        let entries = ordered
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: true).map(String.init) }
            .filter { seen.insert($0).inserted }
        return entries.joined(separator: ":")
    }

    /// Builds the environment a child command runs under: the inherited environment, with the
    /// augmented `PATH`, a truthful `PWD`, and any per-command overrides merged over it. Pure so
    /// it can be tested without spawning anything.
    ///
    /// `PWD` is the reason this exists. Foundation sets a child's working directory through
    /// `currentDirectoryURL`, which changes the actual `getcwd()` but leaves the inherited `PWD`
    /// variable untouched — so the child is handed a shell variable that contradicts where it is
    /// really running. Most tools call `getcwd()` and never notice. `opencode` trusts `PWD`, and
    /// resolved its project root from it: a Review Bot launched from a terminal sitting in some
    /// other repository reviewed *that* repository's files while its diff and thread came from the
    /// pull request, so it produced a confident review of a codebase the PR had nothing to do with.
    /// Nothing in the output marks it as such — the verdict counts toward the panel like any other.
    ///
    /// `OLDPWD` is dropped rather than corrected: it describes a `cd` this process never made, and
    /// there is no honest value for it here.
    ///
    /// Overrides are applied last, so a caller can deliberately override even `PATH` or `PWD`. An
    /// override whose value is `nil` removes the variable outright, which is what unsets an
    /// inherited API key for a reviewer running under session auth.
    ///
    /// Variable names are matched case-insensitively on Windows, where the inherited block spells
    /// the path `Path`: writing `PATH` beside it would hand the child two entries and leave the OS
    /// to pick one. On macOS names are case-sensitive and compared exactly, as they always were.
    static func composeEnvironment(
        inherited: [String: String],
        path: String,
        workingDirectory: String,
        overrides: EnvironmentOverrides
    ) -> [String: String] {
        var environment = inherited
        set(&environment, "PATH", to: path)
        set(&environment, "PWD", to: workingDirectory)
        set(&environment, "OLDPWD", to: nil)
        for (key, value) in overrides {
            set(&environment, key, to: value)
        }
        return environment
    }

    /// Whether two environment variable names refer to the same variable on this platform.
    static func environmentNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        #if os(Windows)
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
        #else
        lhs == rhs
        #endif
    }

    private static func set(_ environment: inout [String: String], _ key: String, to value: String?) {
        for existing in environment.keys where environmentNamesMatch(existing, key) {
            environment.removeValue(forKey: existing)
        }
        if let value {
            environment[key] = value
        }
    }

    func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        timeout: Int = 60
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: [:],
            timeout: timeout
        )
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        timeout: Int
    ) async throws -> CommandResult {
        try await run(
            executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            stopEarly: nil,
            timeout: timeout
        )
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: EnvironmentOverrides,
        stopEarly: OutputWatch?,
        timeout: Int
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            try runSynchronously(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: environment,
                stopEarly: stopEarly,
                timeout: timeout
            )
        }.value
    }

    private func runSynchronously(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment overrides: EnvironmentOverrides,
        stopEarly: OutputWatch?,
        timeout: Int
    ) throws -> CommandResult {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("review-bot-command-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")

        let environment = Self.composeEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            path: Self.augmentedPath,
            // `currentDirectory` is what the child's working directory is set to, so the two
            // cannot drift; when it is nil the child inherits this process's own directory.
            workingDirectory: currentDirectory?.path ?? fileManager.currentDirectoryPath,
            overrides: overrides
        )

        // Only the executable name is surfaced in errors and results. The argument
        // list can contain the full review prompt (plus any REVIEW.md and custom
        // instructions), which must never leak into a posted review, history, or logs.
        let displayCommand = executable

        // The watch reads the output files as the child appends to them, one new line at a
        // time, so a line is judged exactly once. The launcher polls it.
        let watcher = stopEarly.map { OutputFileWatcher(files: [stdoutURL, stderrURL], watch: $0) }
        let started = Date()
        let outcome = try PlatformProcess.launch(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            stdout: stdoutURL,
            stderr: stderrURL,
            timeout: timeout,
            stopWhen: watcher.map { watcher in { watcher.shouldStop() } }
        )

        let stdout = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
        var stderr = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)

        if outcome.timedOut {
            // What the command last said is the only clue to why it hung.
            let lastLine = [stderr, stdout]
                .flatMap { $0.split(whereSeparator: \.isNewline) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            throw CommandExecutionError.timedOut(
                command: displayCommand,
                seconds: timeout,
                detail: lastLine.map { String($0.suffix(300)) }
            )
        }

        if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let detail = outcome.detail {
            stderr = detail
        }
        if outcome.stoppedEarly {
            // Put the reason last, where `conciseError` reads a failure from.
            let elapsed = Int(Date().timeIntervalSince(started).rounded())
            stderr += "\nStopped after \(elapsed) s: \(watcher?.matchedLine ?? "output matched the stop condition")"
        }

        return CommandResult(
            command: displayCommand,
            exitCode: outcome.exitCode,
            stdout: stdout,
            stderr: stderr,
            stoppedEarly: outcome.stoppedEarly
        )
    }
}

/// Feeds the lines a running command appends to its output files to an `OutputWatch`.
///
/// Keeps a read offset and a partial-line buffer per file, so each line is offered once and
/// only once it is complete. Called from the launcher's wait loop, on the thread that is
/// waiting, so it needs no locking.
final class OutputFileWatcher {
    private struct Cursor {
        var offset: UInt64 = 0
        var partial = Data()
    }

    private let files: [URL]
    private let watch: OutputWatch
    private var cursors: [Cursor]
    private(set) var matchedLine: String?

    init(files: [URL], watch: @escaping OutputWatch) {
        self.files = files
        self.watch = watch
        cursors = Array(repeating: Cursor(), count: files.count)
    }

    /// Reads whatever is new in every file and returns true as soon as a line matches.
    func shouldStop() -> Bool {
        if matchedLine != nil { return true }
        for index in files.indices {
            guard let handle = try? FileHandle(forReadingFrom: files[index]) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: cursors[index].offset)
            let data = (try? handle.readToEnd()) ?? Data()
            guard !data.isEmpty else { continue }
            cursors[index].offset += UInt64(data.count)
            var buffer = cursors[index].partial + data
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty, watch(line) {
                    matchedLine = line
                    return true
                }
            }
            cursors[index].partial = buffer
        }
        return false
    }
}
