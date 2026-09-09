// swift-tools-version: 6.0

import PackageDescription

// One code base, two shells. Everything under `Sources/ReviewBot/` that is not in a platform
// folder is the shared core — Foundation only, no AppKit, SwiftUI, Combine or WinSDK — and
// is what `ReviewEngine` and its tests are built from on both platforms. `macOS/` holds the
// menu-bar app (SwiftUI, AppKit, Keychain, launch-at-login); `Windows/` holds the tray app
// (Win32 tray icon, Credential Manager, registry autostart) and the browser dashboard it
// serves. The folder that does not belong to the host is excluded here rather than guarded
// with `#if os(...)` in every file, so a platform's shell reads as ordinary code and the
// shared core cannot quietly grow a platform import — it would fail to build on the other
// side.
//
// The target shapes differ per platform for one reason: SwiftPM renames a testable
// executable's `main` on Darwin and Linux but not on Windows, where linking the test bundle
// against a target that has an entry point fails with a duplicate `main`. So on Windows
// `ReviewBot` is a library and the entry point is `ReviewBotWindows`, a one-file executable
// that calls into it; on macOS it stays the single executable target it always was.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

#if os(Windows)
let package = Package(
    name: "ReviewBot",
    products: [
        .executable(name: "ReviewBot", targets: ["ReviewBotWindows"]),
    ],
    targets: [
        .target(
            name: "ReviewBot",
            exclude: ["macOS"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "ReviewBotWindows",
            dependencies: ["ReviewBot"],
            swiftSettings: swiftSettings,
            linkerSettings: [
                // A tray app must not open a console window. `/SUBSYSTEM:WINDOWS` makes the
                // executable a GUI process; the entry point stays `main` (via the C runtime's
                // `mainCRTStartup`) so the Swift `@main` type is unchanged.
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
            ]
        ),
        .testTarget(
            name: "ReviewBotTests",
            dependencies: ["ReviewBot"],
            exclude: ["macOS"],
            swiftSettings: swiftSettings
        ),
    ]
)
#else
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
            exclude: ["Windows"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ReviewBotTests",
            dependencies: ["ReviewBot"],
            exclude: ["macOS"],
            swiftSettings: swiftSettings
        ),
    ]
)
#endif
