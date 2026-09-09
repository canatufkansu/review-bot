import Foundation

/// Review Bot on Windows: a tray icon and a local dashboard page, over the same engine as the
/// macOS menu-bar app.
///
/// `run` is what the `ReviewBotWindows` executable target's `@main` calls — the only public
/// symbol in the module, because SwiftPM cannot test a Windows target that carries an entry
/// point (see `Package.swift`). It is `async` so the process lives on the Swift concurrency
/// main executor: everything `@MainActor` — the stores, the model, the engine's callbacks —
/// runs on this thread, while the tray's Win32 message loop runs on a thread of its own. The
/// process ends when the model is told to quit, from the tray menu or the page.
public enum ReviewBotWindowsApp {
    @MainActor
    public static func run() async {
        let paths = StoragePaths()
        try? paths.prepare()

        // One Review Bot per user. A second launch — from the Start menu, say — opens the running
        // instance's dashboard, which is what the person most likely wanted, and exits.
        guard WindowsShell.acquireSingleInstance() else {
            if let url = DashboardHandoff.read(from: paths) {
                WindowsShell.open(url)
            }
            return
        }

        let model = WindowsAppModel(paths: paths)

        // The page and its API. The token is minted per launch and reaches the page only via
        // the URL the tray opens; the handoff file records it for a second launch of the app.
        let token = DashboardHandoff.makeToken()
        let api = DashboardAPI(backend: model, token: token)
        let server = LocalHTTPServer { request in await api.handle(request) }
        do {
            let port = try server.start()
            let url = DashboardAPI.dashboardURL(port: port, token: token)
            model.dashboardURL = url
            DashboardHandoff.write(url, to: paths)
        } catch {
            model.report("The dashboard could not start: \(error.localizedDescription)")
        }

        let tray = TrayIcon { action in
            Task { @MainActor in model.perform(action) }
        }
        model.onStateChange = { [weak model] in
            guard let model else { return }
            tray.update(model.trayState)
        }
        tray.start()
        tray.update(model.trayState)
        model.start()

        await model.waitForQuit()

        tray.stop()
        server.stop()
        DashboardHandoff.remove(from: paths)
    }
}

/// Where a running instance's dashboard is, for a second launch to open. Lives in the data
/// folder, which is private to the user's profile — the same trust boundary as `config.json`.
enum DashboardHandoff {
    private static func file(in paths: StoragePaths) -> URL {
        paths.root.appendingPathComponent("dashboard.json")
    }

    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(UInt64.random(in: .min ... .max, using: &generator), radix: 16) }
            .joined()
    }

    static func write(_ url: String, to paths: StoragePaths) {
        let data = try? JSONEncoder().encode(["url": url])
        try? data?.write(to: file(in: paths), options: .atomic)
    }

    static func read(from paths: StoragePaths) -> String? {
        guard let data = try? Data(contentsOf: file(in: paths)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return decoded["url"]
    }

    static func remove(from paths: StoragePaths) {
        try? FileManager.default.removeItem(at: file(in: paths))
    }
}
