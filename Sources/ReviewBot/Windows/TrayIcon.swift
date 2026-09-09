import Foundation
import WinSDK

/// What the tray shows: the tooltip and the state the icon's colour and the menu reflect.
struct TrayState: Sendable, Equatable {
    var status: String
    var isPaused: Bool
    var isRunning: Bool
    var hasFailure: Bool

    static let starting = TrayState(status: "Starting…", isPaused: false, isRunning: false, hasFailure: false)
}

enum TrayAction: Sendable {
    case openDashboard
    case runNow
    case togglePaused
    case openDataFolder
    case quit
}

/// The notification-area icon: the Windows counterpart of the macOS menu-bar extra.
///
/// Win32 delivers tray events as window messages, so the icon needs a window and a message
/// loop, and both must live on the thread that created the window. That thread is started here
/// and owns nothing but the icon: every action is handed to `onAction`, which the app hops back
/// to the main actor with, and every state change arrives through `update`, which posts a
/// message so the redraw happens on the icon's own thread. The main thread stays free for Swift
/// concurrency's main executor, which is what the engine's `@MainActor` stores run on.
final class TrayIcon: @unchecked Sendable {
    /// The window procedure is a C function pointer and cannot capture, so it reaches the one
    /// instance through here.
    fileprivate static var shared: TrayIcon?

    fileprivate static let callbackMessage: UINT = 0x8000 + 1 // WM_APP + 1
    fileprivate static let refreshMessage: UINT = 0x8000 + 2 // WM_APP + 2

    private let onAction: @Sendable (TrayAction) -> Void
    private let lock = NSLock()
    private var state = TrayState.starting
    private var window: HWND?
    private var icon: HICON?
    private var thread: Thread?
    private let started = DispatchSemaphore(value: 0)

    init(onAction: @escaping @Sendable (TrayAction) -> Void) {
        self.onAction = onAction
    }

    /// Creates the icon on its own thread and returns once it is showing.
    func start() {
        Self.shared = self
        let thread = Thread { [self] in run() }
        thread.name = "review-bot-tray"
        self.thread = thread
        thread.start()
        started.wait()
    }

    func update(_ newState: TrayState) {
        lock.lock()
        let changed = state != newState
        state = newState
        let window = self.window
        lock.unlock()
        guard changed, let window else { return }
        PostMessageW(window, Self.refreshMessage, 0, 0)
    }

    func stop() {
        lock.lock()
        let window = self.window
        lock.unlock()
        // WM_CLOSE
        if let window { PostMessageW(window, 0x0010, 0, 0) }
    }

    // MARK: - Icon thread

    private func run() {
        let instance = GetModuleHandleW(nil)
        let className = "ReviewBotTrayWindow"

        var registered = className.withCString(encodedAs: UTF16.self) { name -> Bool in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = trayWindowProcedure
            windowClass.hInstance = instance
            windowClass.lpszClassName = name
            return RegisterClassW(&windowClass) != 0
        }
        // ERROR_CLASS_ALREADY_EXISTS is fine after a restart of the icon in-process.
        if !registered, GetLastError() == 1410 { registered = true }
        guard registered else {
            started.signal()
            return
        }

        let created = className.withCString(encodedAs: UTF16.self) { name in
            "Review Bot".withCString(encodedAs: UTF16.self) { title in
                // A plain, never-shown top-level window. WS_OVERLAPPED, default position and size.
                CreateWindowExW(0, name, title, 0, Int32(bitPattern: 0x8000_0000), Int32(bitPattern: 0x8000_0000),
                                Int32(bitPattern: 0x8000_0000), Int32(bitPattern: 0x8000_0000), nil, nil, instance, nil)
            }
        }
        guard let created else {
            started.signal()
            return
        }

        lock.lock()
        window = created
        lock.unlock()

        icon = Self.makeIcon(for: currentState)
        var data = notifyData(for: created)
        data.uFlags = 0x1 | 0x2 | 0x4 // NIF_MESSAGE | NIF_ICON | NIF_TIP
        data.uCallbackMessage = Self.callbackMessage
        data.hIcon = icon
        writeTip(currentState.status, into: &data)
        _ = Shell_NotifyIconW(0, &data) // NIM_ADD

        started.signal()

        var message = MSG()
        while GetMessageW(&message, nil, 0, 0).boolValue {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }

        var removal = notifyData(for: created)
        _ = Shell_NotifyIconW(2, &removal) // NIM_DELETE
        if let icon { DestroyIcon(icon) }
    }

    private var currentState: TrayState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func notifyData(for window: HWND) -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        return data
    }

    private func writeTip(_ text: String, into data: inout NOTIFYICONDATAW) {
        let tip = Array(text.utf16.prefix(127)) + [0]
        withUnsafeMutablePointer(to: &data.szTip) { pointer in
            pointer.withMemoryRebound(to: WCHAR.self, capacity: 128) { buffer in
                for (index, unit) in tip.enumerated() { buffer[index] = unit }
            }
        }
    }

    /// Redraws the icon and tooltip from the latest state. Runs on the icon thread.
    fileprivate func refresh() {
        guard let window else { return }
        let state = currentState
        let newIcon = Self.makeIcon(for: state)
        var data = notifyData(for: window)
        data.uFlags = 0x2 | 0x4 // NIF_ICON | NIF_TIP
        data.hIcon = newIcon
        writeTip(state.status, into: &data)
        _ = Shell_NotifyIconW(1, &data) // NIM_MODIFY
        if let icon { DestroyIcon(icon) }
        icon = newIcon
    }

    fileprivate func showMenu() {
        guard let window else { return }
        let state = currentState

        let menu = CreatePopupMenu()
        func append(_ id: UInt, _ title: String, enabled: Bool = true) {
            _ = title.withCString(encodedAs: UTF16.self) {
                // MF_STRING, plus MF_GRAYED when disabled.
                AppendMenuW(menu, enabled ? 0x0 : 0x1, UINT_PTR(id), $0)
            }
        }
        append(1, "Open dashboard")
        _ = AppendMenuW(menu, 0x800, 0, nil) // MF_SEPARATOR
        append(2, state.isRunning ? "Reviewing…" : "Run now", enabled: !state.isRunning)
        append(3, state.isPaused ? "Resume monitoring" : "Pause monitoring")
        append(4, "Open data folder")
        _ = AppendMenuW(menu, 0x800, 0, nil)
        append(5, "Quit Review Bot")

        // The documented dance: without a foreground window the menu does not dismiss when the
        // user clicks elsewhere, and without the trailing WM_NULL it can reappear.
        SetForegroundWindow(window)
        var point = POINT()
        GetCursorPos(&point)
        // TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_BOTTOMALIGN | TPM_NONOTIFY
        let chosen = TrackPopupMenu(menu, 0x0002 | 0x0100 | 0x0020 | 0x0080, point.x, point.y, 0, window, nil)
        PostMessageW(window, 0, 0, 0)
        DestroyMenu(menu)

        // With TPM_RETURNCMD the BOOL carries the chosen item id.
        switch unsafeBitCast(chosen, to: Int32.self) {
        case 1: onAction(.openDashboard)
        case 2: onAction(.runNow)
        case 3: onAction(.togglePaused)
        case 4: onAction(.openDataFolder)
        case 5: onAction(.quit)
        default: break
        }
    }

    fileprivate func openDashboard() {
        onAction(.openDashboard)
    }

    fileprivate func destroyed() {
        lock.lock()
        window = nil
        lock.unlock()
    }

    // MARK: - Icon drawing

    /// A filled circle whose colour is the state — green watching, blue reviewing, orange paused,
    /// red after a failure — drawn in memory. No icon resources: the executable is the whole app.
    private static func makeIcon(for state: TrayState) -> HICON? {
        let (red, green, blue): (Double, Double, Double)
        if state.isRunning { (red, green, blue) = (0x2F, 0x6F, 0xED) }
        else if state.isPaused { (red, green, blue) = (0xD9, 0x77, 0x06) }
        else if state.hasFailure { (red, green, blue) = (0xD1, 0x34, 0x38) }
        else { (red, green, blue) = (0x1F, 0x9D, 0x55) }

        let size = 32
        let radius = 13.0
        let centre = Double(size) / 2
        var pixels = [UInt32](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - centre
                let dy = Double(y) + 0.5 - centre
                let distance = (dx * dx + dy * dy).squareRoot()
                let coverage = min(1, max(0, radius + 0.5 - distance))
                guard coverage > 0 else { continue }
                // 32-bit BGRA, premultiplied, as CreateIconIndirect expects for an alpha icon.
                let alpha = UInt32(coverage * 255)
                let b = UInt32(blue * coverage), g = UInt32(green * coverage), r = UInt32(red * coverage)
                pixels[y * size + x] = (alpha << 24) | (r << 16) | (g << 8) | b
            }
        }

        let colour = pixels.withUnsafeBytes { bytes in
            CreateBitmap(Int32(size), Int32(size), 1, 32, bytes.baseAddress)
        }
        let maskBytes = [UInt8](repeating: 0, count: size * size / 8)
        let mask = maskBytes.withUnsafeBytes { bytes in
            CreateBitmap(Int32(size), Int32(size), 1, 1, bytes.baseAddress)
        }
        defer {
            if let colour { DeleteObject(colour) }
            if let mask { DeleteObject(mask) }
        }
        guard let colour, let mask else { return nil }

        var info = ICONINFO()
        info.fIcon = true
        info.hbmMask = mask
        info.hbmColor = colour
        return CreateIconIndirect(&info)
    }
}

/// The tray window's message handler. A free function because Win32 wants a C function pointer.
private func trayWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case TrayIcon.callbackMessage:
        // The low word of lParam is the mouse message on the icon.
        switch UInt32(lParam & 0xFFFF) {
        case 0x0203: // WM_LBUTTONDBLCLK
            TrayIcon.shared?.openDashboard()
        case 0x0205, 0x007B: // WM_RBUTTONUP, WM_CONTEXTMENU
            TrayIcon.shared?.showMenu()
        default:
            break
        }
        return 0
    case TrayIcon.refreshMessage:
        TrayIcon.shared?.refresh()
        return 0
    case 0x0010: // WM_CLOSE
        DestroyWindow(window)
        return 0
    case 0x0002: // WM_DESTROY
        TrayIcon.shared?.destroyed()
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(window, message, wParam, lParam)
    }
}
