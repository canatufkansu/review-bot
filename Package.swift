// swift-tools-version: 6.0

import PackageDescription

// One target, two shells. Everything under `Sources/ReviewBot/` that is not in a platform
// folder is the shared core — Foundation only, no AppKit, SwiftUI, Combine or WinSDK — and
// is what `ReviewEngine` and its tests are built from on both platforms. `macOS/` holds the
// menu-bar app (SwiftUI, AppKit, Keychain, launch-at-login); `Windows/` holds the tray app
// (Win32 tray icon, Credential Manager, registry autostart) and the browser dashboard it
// serves. The folder that does not belong to the host is excluded here rather than guarded
// with `#if os(...)` in every file, so a platform's shell reads as ordinary code and the
// shared core cannot quietly grow a platform import — it would fail to build on the other
// side.
#if os(Windows)
let platformExcludedSources = ["macOS"]
let platformExcludedTests = ["macOS"]
#else
let platformExcludedSources = ["Windows"]
let platformExcludedTests = ["Windows"]
#endif

let package = Package(
    name: "ReviewBot",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ReviewBot", targets: ["ReviewBot"]),
    ],
    targets: [
        .executableTarget(
            name: "ReviewBot",
            exclude: platformExcludedSources,
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                // A tray app must not open a console window. `/SUBSYSTEM:WINDOWS` makes the
                // executable a GUI process; the entry point stays `main` (via the C runtime's
                // `mainCRTStartup`) so the Swift `@main` type is unchanged.
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows])
                ),
            ]
        ),
        .testTarget(
            name: "ReviewBotTests",
            dependencies: ["ReviewBot"],
            exclude: platformExcludedTests,
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
