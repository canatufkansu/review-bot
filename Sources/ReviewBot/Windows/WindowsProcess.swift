import Foundation
import WinSDK

/// How Windows starts a command. This is the launcher `ProcessRunner` uses on Windows;
/// `UnixProcess.swift` is the macOS one.
///
/// Two things differ from macOS. There is no `env` and no `perl`, and no Foundation `Process`
/// either — see `launch` for why `CreateProcessW` is called directly: the command is resolved
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
        stdout: URL,
        stderr: URL,
        timeout: Int
    ) throws -> LaunchOutcome {
        let resolved = try resolve(executable)

        // `CreateProcessW` directly rather than Foundation's `Process`, for three things it
        // cannot give: `CREATE_NO_WINDOW`, without which every git and gh call from this
        // console-less app flashes a console window; `CREATE_SUSPENDED`, so the child is in
        // the job before it runs a single instruction; and the raw exit code, so a child that
        // died of an exception is reported as such instead of as a bare number.
        let job = JobObject()
        var standardInput = try openHandle(path: "NUL", forWriting: false)
        defer { standardInput.close() }
        var standardOutput = try openHandle(path: WindowsShell.nativePath(stdout), forWriting: true)
        defer { standardOutput.close() }
        var standardError = try openHandle(path: WindowsShell.nativePath(stderr), forWriting: true)
        defer { standardError.close() }

        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        startup.dwFlags = 0x100 // STARTF_USESTDHANDLES
        startup.hStdInput = standardInput.handle
        startup.hStdOutput = standardOutput.handle
        startup.hStdError = standardError.handle
        var information = PROCESS_INFORMATION()

        var application = Array(resolved.executable.utf16) + [0]
        var commandLine = Array(
            WindowsCommandLine.quote([resolved.executable] + resolved.leadingArguments + arguments).utf16
        ) + [0]
        var block = WindowsCommandLine.environmentBlock(environment)
        var directory = currentDirectory.map { Array(WindowsShell.nativePath($0).utf16) + [0] }

        // CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW | CREATE_SUSPENDED
        let flags: DWORD = 0x400 | 0x0800_0000 | 0x4
        let created = application.withUnsafeMutableBufferPointer { applicationPointer in
            commandLine.withUnsafeMutableBufferPointer { commandPointer in
                block.withUnsafeMutableBytes { blockPointer in
                    withOptionalDirectory(&directory) { directoryPointer in
                        CreateProcessW(
                            applicationPointer.baseAddress, commandPointer.baseAddress,
                            nil, nil, true, flags, blockPointer.baseAddress,
                            directoryPointer, &startup, &information
                        )
                    }
                }
            }
        }
        guard created else {
            throw CommandExecutionError.launchFailed(
                command: executable,
                detail: "CreateProcess failed with error \(GetLastError()) for \(resolved.executable)"
            )
        }
        defer {
            CloseHandle(information.hThread)
            CloseHandle(information.hProcess)
            // Closing the job kills any grandchild the CLI left behind, so a review never leaks
            // a language server or a node helper into the background.
            job.close()
        }

        job.assign(process: information.hProcess)
        ResumeThread(information.hThread)

        // Our copies of the child's standard handles are closed now that it holds its own;
        // otherwise the files stay open for writing until this call returns.
        standardInput.close()
        standardOutput.close()
        standardError.close()

        var timedOut = false
        // WAIT_TIMEOUT
        if WaitForSingleObject(information.hProcess, DWORD(max(1, timeout)) * 1000) == 0x102 {
            timedOut = true
            if !job.terminate() {
                TerminateProcess(information.hProcess, 1)
            }
            WaitForSingleObject(information.hProcess, INFINITE)
        }

        var rawExitCode: DWORD = 0
        GetExitCodeProcess(information.hProcess, &rawExitCode)
        var detail: String?
        if rawExitCode & 0xF000_0000 != 0 {
            // An NTSTATUS/HRESULT: the process did not return, it was killed by an exception
            // (access violation, missing DLL, stack overflow) — or by a debugger, or by Windows.
            detail = String(format: "process ended abnormally with status 0x%08X", rawExitCode)
        }
        return LaunchOutcome(exitCode: Int32(bitPattern: rawExitCode), timedOut: timedOut, detail: detail)
    }

    /// An inheritable file handle for a child's standard stream.
    private struct InheritableHandle {
        var handle: HANDLE?

        mutating func close() {
            if let handle { CloseHandle(handle) }
            handle = nil
        }
    }

    private static func openHandle(path: String, forWriting: Bool) throws -> InheritableHandle {
        var security = SECURITY_ATTRIBUTES()
        security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        security.bInheritHandle = true
        let handle = path.withCString(encodedAs: UTF16.self) { name in
            CreateFileW(
                name,
                forWriting ? 0x4000_0000 : 0x8000_0000, // GENERIC_WRITE : GENERIC_READ
                0x1 | 0x2, // FILE_SHARE_READ | FILE_SHARE_WRITE
                &security,
                forWriting ? 2 : 3, // CREATE_ALWAYS : OPEN_EXISTING
                0x80, // FILE_ATTRIBUTE_NORMAL
                nil
            )
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw CommandExecutionError.launchFailed(
                command: path,
                detail: "could not open \(path) for the child's standard streams (error \(GetLastError()))"
            )
        }
        return InheritableHandle(handle: handle)
    }

    private static func withOptionalDirectory<T>(
        _ directory: inout [UInt16]?,
        _ body: (UnsafePointer<UInt16>?) -> T
    ) -> T {
        guard directory != nil else { return body(nil) }
        return directory!.withUnsafeBufferPointer { body($0.baseAddress) }
    }

    static func locate(_ command: String) -> String? {
        (try? resolve(command))?.executable
    }

    private static func directory(of path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "." }
        return String(path[..<index])
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

        func assign(process: HANDLE?) {
            guard let handle, let process else { return }
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
