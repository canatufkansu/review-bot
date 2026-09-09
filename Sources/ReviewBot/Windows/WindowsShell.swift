import Foundation
import WinSDK

/// The handful of things the Windows shell asks the OS for outside process launching: opening
/// a URL or folder, the executable's own path, the autostart registration, and the
/// single-instance guard.
enum WindowsShell {
    /// Opens `target` — an `http` URL or a folder path — with whatever handles it.
    static func open(_ target: String) {
        _ = "open".withCString(encodedAs: UTF16.self) { verb in
            target.withCString(encodedAs: UTF16.self) { file in
                // SW_SHOWNORMAL
                ShellExecuteW(nil, verb, file, nil, nil, 1)
            }
        }
    }

    /// The running executable, as `GetModuleFileNameW` reports it.
    static let executablePath: String = {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
    }()

    /// The folder the executable lives in.
    static var executableDirectory: String {
        guard let index = executablePath.lastIndex(of: "\\") else { return "." }
        return String(executablePath[..<index])
    }

    /// The release version, stamped by `scripts\build-windows.ps1` into `version.txt` beside
    /// the executable; `dev` for a plain `swift build`.
    static let version: String = {
        let file = executableDirectory + "\\version.txt"
        let text = (try? String(contentsOfFile: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "dev" : text
    }()

    /// The path `url` names, in the form Windows APIs and `Explorer` expect (`C:\…`).
    static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { String(cString: $0) } ?? url.path
        }
    }

    // MARK: - Single instance

    private static var instanceMutex: HANDLE?

    /// Claims the per-user instance mutex. `false` means another Review Bot is already running
    /// for this user, and this one should hand off to it rather than start a second tray icon.
    static func acquireSingleInstance() -> Bool {
        let handle = "Local\\ReviewBot.SingleInstance".withCString(encodedAs: UTF16.self) {
            CreateMutexW(nil, false, $0)
        }
        guard handle != nil else { return true }
        // ERROR_ALREADY_EXISTS
        if GetLastError() == 183 {
            CloseHandle(handle)
            return false
        }
        instanceMutex = handle
        return true
    }

    // MARK: - Launch at login

    /// Autostart through the per-user `Run` key: the Windows equivalent of a login item, and the
    /// one that needs no installer — it points at wherever the executable is.
    enum LaunchAtLogin {
        private static let runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
        private static let valueName = "Review Bot"

        static var isEnabled: Bool {
            // KEY_QUERY_VALUE
            guard let key = openRunKey(access: 0x0001) else { return false }
            defer { RegCloseKey(key) }
            var size: DWORD = 0
            let status = valueName.withCString(encodedAs: UTF16.self) {
                RegQueryValueExW(key, $0, nil, nil, nil, &size)
            }
            return status == 0 // ERROR_SUCCESS
        }

        static func set(_ enabled: Bool) throws {
            // KEY_SET_VALUE
            guard let key = openRunKey(access: 0x0002) else {
                throw LaunchAtLoginError.registry("could not open the Run key")
            }
            defer { RegCloseKey(key) }

            if enabled {
                // The path is quoted so a space in it (`C:\Program Files\…`) is not read as an
                // argument boundary. UTF-16 with its terminator, as REG_SZ wants.
                let command = "\"\(executablePath)\""
                let bytes = Array(command.utf16) + [0]
                let status = valueName.withCString(encodedAs: UTF16.self) { name in
                    bytes.withUnsafeBufferPointer { buffer in
                        buffer.baseAddress!.withMemoryRebound(to: BYTE.self, capacity: buffer.count * 2) {
                            // REG_SZ
                            RegSetValueExW(key, name, 0, 1, $0, DWORD(buffer.count * 2))
                        }
                    }
                }
                guard status == 0 else { throw LaunchAtLoginError.registry("RegSetValueEx failed (\(status))") }
            } else {
                let status = valueName.withCString(encodedAs: UTF16.self) { RegDeleteValueW(key, $0) }
                // ERROR_FILE_NOT_FOUND: already off.
                guard status == 0 || status == 2 else {
                    throw LaunchAtLoginError.registry("RegDeleteValue failed (\(status))")
                }
            }
        }

        private static func openRunKey(access: DWORD) -> HKEY? {
            var key: HKEY?
            let status = runKey.withCString(encodedAs: UTF16.self) { path in
                RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nil, 0, access, nil, &key, nil)
            }
            return status == 0 ? key : nil
        }
    }

    enum LaunchAtLoginError: LocalizedError {
        case registry(String)

        var errorDescription: String? {
            switch self {
            case let .registry(detail): "Could not update the startup entry: \(detail)."
            }
        }
    }
}
