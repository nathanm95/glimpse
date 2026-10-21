import AppKit

@main
@MainActor
enum GlimpseApp {
    static func main() {
        if DebugModes.run(CommandLine.arguments) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
