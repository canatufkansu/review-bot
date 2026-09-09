import XCTest
@testable import ReviewBot

/// The Windows command-resolution logic runs on every platform: it is pure, takes the
/// filesystem as a closure, and is the part of the Windows launcher most likely to be wrong —
/// so it is tested here, on macOS CI too, rather than only where it is used.
final class WindowsCommandResolutionTests: XCTestCase {
    private let home = #"C:\Users\dev"#
    private let inherited = #"C:\Windows\system32;C:\Windows;C:\Program Files\nodejs\"#

    func testComposePATHKeepsTheInheritedPathFirstAndAppendsInstallerDirectories() {
        let composed = WindowsCommandResolution.composePATH(
            inherited: inherited,
            home: home,
            appData: #"C:\Users\dev\AppData\Roaming"#,
            localAppData: #"C:\Users\dev\AppData\Local"#,
            programFiles: #"C:\Program Files"#
        )
        let entries = composed.split(separator: ";").map(String.init)

        XCTAssertEqual(entries.first, #"C:\Windows\system32"#)
        XCTAssertTrue(entries.contains(#"C:\Users\dev\AppData\Roaming\npm"#))
        XCTAssertTrue(entries.contains(#"C:\Users\dev\.local\bin"#))
        XCTAssertTrue(entries.contains(#"C:\Program Files\GitHub CLI"#))
        XCTAssertTrue(entries.contains(#"C:\Users\dev\AppData\Local\Microsoft\WinGet\Links"#))
        // An installer directory the environment did not name is still appended, never inserted
        // ahead of a directory the user put on Path themselves.
        XCTAssertLessThan(
            entries.firstIndex(of: #"C:\Program Files\nodejs\"#)!,
            entries.firstIndex(of: #"C:\Users\dev\AppData\Roaming\npm"#)!
        )
    }

    func testComposePATHDeduplicatesCaseInsensitivelyAndDropsBlanks() {
        let composed = WindowsCommandResolution.composePATH(
            inherited: #"C:\Tools;;c:\tools; C:\Users\dev\.local\bin "#,
            home: home,
            appData: nil,
            localAppData: nil,
            programFiles: nil
        )
        let entries = composed.split(separator: ";").map(String.init)

        XCTAssertEqual(entries, [#"C:\Tools"#, #"C:\Users\dev\.local\bin"#, #"C:\Users\dev\scoop\shims"#])
    }

    func testResolveTriesEachExtensionInADirectoryBeforeMovingOn() {
        let files: Set<String> = [
            #"C:\Users\dev\AppData\Roaming\npm\claude.cmd"#,
            #"C:\Users\dev\.local\bin\claude.exe"#,
        ]
        let path = #"C:\Users\dev\AppData\Roaming\npm;C:\Users\dev\.local\bin"#

        let resolved = WindowsCommandResolution.resolve("claude", path: path) { files.contains($0) }

        // The npm shim comes first on Path, so it wins — exactly as cmd.exe would pick it. The
        // launcher then unwraps it rather than skipping it, so the user's ordering is honoured.
        XCTAssertEqual(resolved, #"C:\Users\dev\AppData\Roaming\npm\claude.cmd"#)
    }

    func testResolvePrefersExeOverCmdWithinOneDirectory() {
        let files: Set<String> = [#"C:\bin\gh.exe"#, #"C:\bin\gh.cmd"#]
        XCTAssertEqual(
            WindowsCommandResolution.resolve("gh", path: #"C:\bin"#) { files.contains($0) },
            #"C:\bin\gh.exe"#
        )
    }

    func testResolveHonoursAnExplicitExtensionAndAnExplicitPath() {
        let files: Set<String> = [#"C:\bin\git.exe"#, #"D:\tools\codex.exe"#]
        XCTAssertEqual(
            WindowsCommandResolution.resolve("git.exe", path: #"C:\bin"#) { files.contains($0) },
            #"C:\bin\git.exe"#
        )
        XCTAssertNil(WindowsCommandResolution.resolve("git.cmd", path: #"C:\bin"#) { files.contains($0) })
        XCTAssertEqual(
            WindowsCommandResolution.resolve(#"D:\tools\codex.exe"#, path: #"C:\bin"#) { files.contains($0) },
            #"D:\tools\codex.exe"#
        )
        XCTAssertNil(WindowsCommandResolution.resolve("nothing", path: #"C:\bin"#) { files.contains($0) })
    }

    func testBatchFilesAreRecognisedByExtensionOnly() {
        XCTAssertTrue(WindowsCommandResolution.isBatchFile(#"C:\x\claude.CMD"#))
        XCTAssertTrue(WindowsCommandResolution.isBatchFile(#"C:\x\run.bat"#))
        XCTAssertFalse(WindowsCommandResolution.isBatchFile(#"C:\x\claude.exe"#))
    }

    // MARK: - npm shims

    /// The launcher npm writes for a global package on Windows, verbatim.
    private let npmShim = """
    @ECHO off
    GOTO start
    :find_dp0
    SET dp0=%~dp0
    EXIT /b
    :start
    SETLOCAL
    CALL :find_dp0

    IF EXIST "%dp0%\\node.exe" (
      SET "_prog=%dp0%\\node.exe"
    ) ELSE (
      SET "_prog=node"
      SET PATHEXT=%PATHEXT:;.JS;=;%
    )

    endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@anthropic-ai\\claude-code\\cli.js" %*
    """

    func testNpmShimIsUnwrappedToItsScript() throws {
        let shim = try XCTUnwrap(NpmShim.parse(
            contents: npmShim,
            directory: #"C:\Users\dev\AppData\Roaming\npm"#
        ))

        XCTAssertEqual(
            shim.script,
            #"C:\Users\dev\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"#
        )
        // `%dp0%` expands with a trailing backslash, so the template's own `\` must not double it.
        XCTAssertFalse(shim.script.contains(#"\\"#))
        XCTAssertEqual(shim.bundledInterpreter, #"C:\Users\dev\AppData\Roaming\npm\node.exe"#)
    }

    func testNpmShimDirectoryWithTrailingBackslashIsNotDoubled() throws {
        let shim = try XCTUnwrap(NpmShim.parse(contents: npmShim, directory: #"C:\npm\"#))
        XCTAssertEqual(shim.script, #"C:\npm\node_modules\@anthropic-ai\claude-code\cli.js"#)
    }

    func testAnUnfamiliarBatchFileIsRefusedRatherThanGuessed() {
        // A batch file that is not an npm shim: no `%_prog%`, so nothing to unwrap. The launcher
        // then refuses to run it through cmd.exe instead of inventing a command line.
        let batch = """
        @echo off
        node "C:\\tools\\thing.js" %*
        """
        XCTAssertNil(NpmShim.parse(contents: batch, directory: #"C:\tools"#))
    }
}

/// The bytes handed to `CreateProcessW`. A wrong quote here would hand a CLI a prompt cut at
/// its first space; a wrong environment block would hand it no `Path` at all.
final class WindowsCommandLineTests: XCTestCase {
    func testPlainArgumentsAreLeftAlone() {
        XCTAssertEqual(
            WindowsCommandLine.quote([#"C:\Program Files\Git\cmd\git.exe"#, "-C", #"C:\src\repo"#, "fetch"]),
            #""C:\Program Files\Git\cmd\git.exe" -C C:\src\repo fetch"#
        )
    }

    func testSpacesQuotesAndNewlinesAreQuotedTheWayTheCRuntimeSplitsThem() {
        XCTAssertEqual(WindowsCommandLine.quoteArgument("a b"), #""a b""#)
        XCTAssertEqual(WindowsCommandLine.quoteArgument(""), #""""#)
        XCTAssertEqual(WindowsCommandLine.quoteArgument(#"say "hi""#), #""say \"hi\"""#)
        // Backslashes before a quote double; elsewhere they are literal.
        XCTAssertEqual(WindowsCommandLine.quoteArgument(#"C:\dir\"#), #""C:\dir\\""#)
        XCTAssertEqual(WindowsCommandLine.quoteArgument(#"x\"y"#), #""x\\\"y""#)
        XCTAssertEqual(WindowsCommandLine.quoteArgument(#"C:\dir with space\file"#), #""C:\dir with space\file""#)
        // A prompt: multi-line, quoted as one argument.
        XCTAssertEqual(WindowsCommandLine.quoteArgument("Review this.\nBe strict."), "\"Review this.\nBe strict.\"")
    }

    func testEnvironmentBlockIsSortedAndDoubleTerminated() {
        let block = WindowsCommandLine.environmentBlock(["Path": "C:\\bin", "APPDATA": "C:\\a", "b": "2"])
        let text = String(decoding: block, as: UTF16.self)
        XCTAssertEqual(text, "APPDATA=C:\\a\0b=2\0Path=C:\\bin\0\0")
        XCTAssertEqual(String(decoding: WindowsCommandLine.environmentBlock([:]), as: UTF16.self), "\0\0")
    }
}
