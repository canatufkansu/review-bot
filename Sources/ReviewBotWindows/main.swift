import ReviewBot

// The Windows executable: nothing but the entry point. Everything else is in the `ReviewBot`
// module so that module can be tested — see the note in `Package.swift`.
@main
enum ReviewBotWindowsMain {
    static func main() async {
        await ReviewBotWindowsApp.run()
    }
}
