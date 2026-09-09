import Foundation
import WinSDK

/// How Windows starts a command. This is the launcher `ProcessRunner` uses on Windows;
/// `UnixProcess.swift` is the macOS one.
///
/// Two things differ from macOS. There is no `env` and no `perl`: the command is resolved
/// here, with `WindowsCommandResolution`, into a real executable — an npm `.cmd` launcher is
/// unwrapped into `node.exe <script>` rather than run through `cmd.exe`, which would re-parse
/// the review prompt. And the time limit is a job object: the child is placed in one with
/// kill-on-close set, so the whole tree it spawns (a Node CLI forks freely) dies with it when
/// the limit fires or when this process closes the job — including if Review Bot itself is
/// killed, which `perl alarm` never had to worry about because the alarm lived in the child.
enum PlatformProcess: PlatformProcessLaunching {
    static let augmentedPATH: String = WindowsCommandResolution.composePATH(
        inherited: environmentValue("Path") ?? "",
        home: homeDirectory,
        appData: environmentValue("APPDATA"),
        localAppData: environmentValue("LOCALAPPDATA"),
        programFiles: environmentValue("ProgramFiles")
    )

    /// `%USERPROFILE%`, which is the Windows home directory as installers spell it; Foundation's
    /// home URL is the fallback for an environment stripped of it.
    static var homeDirectory: String {
        environmentValue("USERPROFILE") ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Environment names are case-insensitive on Windows and the inherited block spells them
    /// however the parent did (`Path`, `PATH`, `path`), so lookups must be too.
    static func environmentValue(_ name: String) -> String? {
        ProcessInfo.processInfo.environment.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    /// A command turned into something `CreateProcess` can start.
    struct ResolvedCommand {
        var executable: String
        /// Arguments that go before the caller's — the script, when the command is an npm shim.
        var leadingArguments: [String]
    }

    static func resolve(_ command: String) throws -> ResolvedCommand {
        let fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        guard let found = WindowsCommandResolution.resolve(
            command,
            path: augmentedPATH,
            fileExists: fileExists
        ) else {
            throw CommandExecutionError.notFound(
                command: command,
                detail: "not found on PATH. Install it, or add its folder to your Path variable."
            )
        }
        guard WindowsCommandResolution.isBatchFile(found) else {
            return ResolvedCommand(executable: found, leadingArguments: [])
        }

        // A batch file. The only kind Review Bot runs is npm's launcher, and it runs that by
        // starting the interpreter on the script itself.
        let contents = (try? String(contentsOfFile: found, encoding: .utf8)) ?? ""
        guard let shim = NpmShim.parse(contents: contents, directory: directory(of: found)) else {
            throw CommandExecutionError.notFound(
                command: command,
                detail: "`\(found)` is a batch file, which Review Bot does not run through "
                    + "cmd.exe because the review prompt would be re-parsed by the shell. "
                    + "Install the native executable instead."
            )
        }
        let interpreter = shim.bundledInterpreter.flatMap { fileExists($0) ? $0 : nil }
            ?? WindowsCommandResolution.resolve("node.exe", path: augmentedPATH, fileExists: fileExists)
        guard let interpreter else {
            throw CommandExecutionError.notFound(
                command: command,
                detail: "`\(found)` is an npm launcher for `\(shim.script)`, but node.exe is not "
                    + "on PATH."
            )
        }
        return ResolvedCommand(executable: interpreter, leadingArguments: [shim.script])
    }

    static func launch(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        stdout: FileHandle,
        stderr: FileHandle,
        timeout: Int
    ) throws -> LaunchOutcome {
        let resolved = try resolve(executable)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved.executable)
        process.arguments = resolved.leadingArguments + arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.environment = environment

        try process.run()

        let job = JobObject()
        job.assign(processID: process.processIdentifier)

        // The limit. Fired from a background queue, it kills the job — the child and everything
        // it started — and records that it did so. `isRunning` is checked under the lock so a
        // child that exits in the same instant the limit fires is not reported as timed out.
        let watchdog = Watchdog()
        let limit = DispatchWorkItem {
            watchdog.fire {
                guard process.isRunning else { return false }
                if !job.terminate() {
                    process.terminate()
                }
                return true
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(max(1, timeout)),
            execute: limit
        )

        process.waitUntilExit()
        limit.cancel()
        // Closing the job kills any grandchild the CLI left behind, so a review never leaks a
        // language server or a node helper into the background.
        job.close()

        return LaunchOutcome(exitCode: process.terminationStatus, timedOut: watchdog.didFire)
    }

    static func locate(_ command: String) -> String? {
        (try? resolve(command))?.executable
    }

    private static func directory(of path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "." }
        return String(path[..<index])
    }

    /// Records whether the time limit ran, under a lock shared with the exit path.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func fire(_ body: () -> Bool) {
            lock.lock()
            defer { lock.unlock() }
            if body() { fired = true }
        }

        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    /// A kill-on-close job object. Every method tolerates a job that could not be created, in
    /// which case the launcher falls back to terminating the direct child only.
    private final class JobObject: @unchecked Sendable {
        private var handle: HANDLE?

        init() {
            guard let job = CreateJobObjectW(nil, nil) else { return }
            var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
            // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; the header defines it as a macro.
            limits.BasicLimitInformation.LimitFlags = 0x2000
            let applied = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &limits,
                DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)
            )
            guard applied else {
                CloseHandle(job)
                return
            }
            handle = job
        }

        func assign(processID: Int32) {
            guard let handle else { return }
            // PROCESS_SET_QUOTA | PROCESS_TERMINATE: what `AssignProcessToJobObject` requires.
            guard let process = OpenProcess(0x0100 | 0x0001, false, DWORD(bitPattern: processID)) else {
                return
            }
            defer { CloseHandle(process) }
            _ = AssignProcessToJobObject(handle, process)
        }

        /// Kills everything in the job. `false` when there is no job to kill.
        func terminate() -> Bool {
            guard let handle else { return false }
            return TerminateJobObject(handle, 1)
        }

        func close() {
            guard let handle else { return }
            CloseHandle(handle)
            self.handle = nil
        }
    }
}
