import Foundation

/// The pure half of how Windows finds a command: composing the search path, walking it with
/// `PATHEXT` semantics, and seeing through npm's `.cmd` launchers. Foundation only, and every
/// filesystem question is asked through a closure, so it compiles and is tested on macOS too —
/// this is the logic most likely to be wrong, and the platform folder that calls it is the
/// part that can only be compiled in CI.
enum WindowsCommandResolution {
    /// Windows already gives a Start-menu-launched app the user's full `Path` — there is no
    /// launchd-style minimal environment to recover from — so the only additions are the
    /// directories installers use that a user may not have put on `Path` themselves: npm's
    /// global prefix, the native `claude` installer's `~\.local\bin`, scoop's shims, winget's
    /// links, and the GitHub CLI and Git installers under Program Files. The inherited value
    /// comes first so a deliberate override on `Path` keeps winning.
    static func composePATH(
        inherited: String,
        home: String,
        appData: String?,
        localAppData: String?,
        programFiles: String?
    ) -> String {
        var preferred: [String] = []
        if let appData {
            preferred.append("\(appData)\\npm")
        }
        preferred.append("\(home)\\.local\\bin")
        preferred.append("\(home)\\scoop\\shims")
        if let localAppData {
            preferred.append("\(localAppData)\\Microsoft\\WinGet\\Links")
            preferred.append("\(localAppData)\\Programs\\Git\\cmd")
        }
        if let programFiles {
            preferred.append("\(programFiles)\\GitHub CLI")
            preferred.append("\(programFiles)\\Git\\cmd")
        }

        var seen = Set<String>()
        let entries = ([inherited] + preferred)
            .flatMap { $0.split(separator: ";", omittingEmptySubsequences: true).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
        return entries.joined(separator: ";")
    }

    /// The extensions tried, in order, when a command is named without one. Deliberately not
    /// the user's `PATHEXT`: that list exists for `cmd.exe`, which can run anything on it, while
    /// this app can only start a real executable or a launcher it knows how to unwrap.
    static let executableExtensions = [".exe", ".cmd", ".bat"]

    /// The file a command name resolves to on `path`, or `nil`.
    ///
    /// Each directory is tried with each extension before moving to the next directory, which is
    /// what `cmd.exe` does and what a user who put a directory first on `Path` expects. A name
    /// that already carries a path separator is taken as given.
    static func resolve(
        _ command: String,
        path: String,
        fileExists: (String) -> Bool
    ) -> String? {
        if command.contains("\\") || command.contains("/") {
            return fileExists(command) ? command : nil
        }
        let hasExtension = executableExtensions.contains {
            command.lowercased().hasSuffix($0)
        }
        for directory in path.split(separator: ";", omittingEmptySubsequences: true) {
            let base = "\(directory)\\\(command)"
            if hasExtension {
                if fileExists(base) { return base }
                continue
            }
            for ext in executableExtensions where fileExists(base + ext) {
                return base + ext
            }
        }
        return nil
    }

    /// Whether a resolved path is a batch launcher rather than a program. Batch files can only be
    /// run through `cmd.exe`, and `cmd.exe` re-parses its command line: a review prompt with a
    /// newline, a `%`, or an `&` in it would be cut or executed. Review Bot never runs one; it
    /// unwraps the ones it understands (`NpmShim`) and refuses the rest.
    static func isBatchFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".cmd") || lower.hasSuffix(".bat")
    }
}

/// What an npm-installed command looks like on Windows, and how to run it without `cmd.exe`.
///
/// `npm install -g` puts no executable on `Path`; it writes `claude.cmd`, a batch file that
/// runs `node.exe` on the package's entry script. Every such shim (`cmd-shim`, npm's own
/// generator) ends with the same line — the program, then the script path relative to the
/// shim's own directory via `%dp0%`:
///
///     endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\node_modules\@anthropic-ai\claude-code\cli.js" %*
///
/// Running `node.exe <script>` directly gives exactly what the shim would have run, minus the
/// shell in between — so the prompt reaches the CLI byte-for-byte, and `CreateProcess`'s
/// argument quoting is the only quoting in play.
struct NpmShim: Equatable {
    /// The script the shim runs, as an absolute path.
    var script: String
    /// The interpreter beside the shim, when the shim was generated with one (`%dp0%\node.exe`),
    /// otherwise `nil` and `node` is looked up on `Path`.
    var bundledInterpreter: String?

    /// Parses the contents of a `.cmd` file living in `directory`. Returns `nil` for anything that
    /// is not recognisably an npm shim, so an unfamiliar batch file is refused rather than guessed
    /// at.
    static func parse(contents: String, directory: String) -> NpmShim? {
        // The launcher line is the one that references `%_prog%` and a `%dp0%`-relative script.
        // Quoted paths are taken verbatim; anything else on the line (`%*`, redirections) is
        // ignored. `%dp0%` carries the shim's directory *with* its trailing backslash, so the
        // literal `\` that follows it in the template is collapsed rather than doubled.
        for line in contents.split(whereSeparator: \.isNewline) {
            guard line.contains("%_prog%"), line.contains("%dp0%") else { continue }
            let quoted = quotedSegments(in: String(line))
            guard let scriptTemplate = quoted.first(where: { $0.contains("%dp0%") && $0 != "%_prog%" }) else {
                continue
            }
            let script = expand(scriptTemplate, directory: directory)
            let bundled = contents.contains("\"%dp0%\\node.exe\"")
                ? expand("%dp0%\\node.exe", directory: directory)
                : nil
            return NpmShim(script: script, bundledInterpreter: bundled)
        }
        return nil
    }

    private static func expand(_ template: String, directory: String) -> String {
        let base = directory.hasSuffix("\\") ? String(directory.dropLast()) : directory
        return template
            .replacingOccurrences(of: "%dp0%\\", with: base + "\\")
            .replacingOccurrences(of: "%dp0%", with: base + "\\")
    }

    private static func quotedSegments(in line: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inside = false
        for character in line {
            if character == "\"" {
                if inside { segments.append(current); current = "" }
                inside.toggle()
            } else if inside {
                current.append(character)
            }
        }
        return segments
    }
}

/// The two byte-exact encodings `CreateProcessW` takes, built here so they can be tested
/// without Windows: the single command-line string a child parses back into `argv`, and the
/// environment block.
enum WindowsCommandLine {
    /// Joins arguments into one command line under the C runtime's parsing rules — the ones
    /// every `main(argc, argv)` on Windows, Node and Go included, use to split it again.
    ///
    /// An argument is quoted when it is empty or contains a space, tab or quote. Inside quotes
    /// a `"` becomes `\"`, and only backslashes that precede a quote (or the closing quote) are
    /// doubled; a backslash anywhere else is literal, which is why `C:\Users\x` needs no
    /// escaping. Review prompts go through here as one argument, newlines and all: the runtime
    /// splits on whitespace outside quotes only, so a quoted argument keeps its newlines.
    static func quote(_ arguments: [String]) -> String {
        arguments.map(quoteArgument).joined(separator: " ")
    }

    static func quoteArgument(_ argument: String) -> String {
        let needsQuotes = argument.isEmpty || argument.contains { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
                continue
            }
            if character == "\"" {
                result += String(repeating: "\\", count: backslashes * 2 + 1)
                result.append("\"")
            } else {
                result += String(repeating: "\\", count: backslashes)
                result.append(character)
            }
            backslashes = 0
        }
        result += String(repeating: "\\", count: backslashes * 2)
        result += "\""
        return result
    }

    /// The `name=value` block, as UTF-16 with the double terminator `CreateProcessW` wants.
    /// Sorted case-insensitively by name, which is the layout Windows itself produces and the
    /// one some runtimes binary-search.
    static func environmentBlock(_ environment: [String: String]) -> [UInt16] {
        let entries = environment
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key)=\($0.value)" }
        var block: [UInt16] = []
        for entry in entries {
            block.append(contentsOf: entry.utf16)
            block.append(0)
        }
        block.append(0)
        if entries.isEmpty { block.append(0) }
        return block
    }
}
