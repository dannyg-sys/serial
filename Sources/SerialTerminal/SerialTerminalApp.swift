import SwiftUI
import AppKit

/// Entry point. A `--list-ssh-hosts` flag prints discovered ssh-config hosts and
/// exits before any window or control server starts (safe to run alongside a
/// running instance); otherwise the GUI app launches normally.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--list-ssh-hosts") {
            for h in SSHConfig.discoverHosts() {
                print(h.alias + (h.subtitle.map { "\t\($0)" } ?? ""))
            }
            return
        }
        SerialTerminalApp.main()
    }
}

struct SerialTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Serial Terminal") {
            ContentView()
                .environmentObject(appDelegate.session)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = SerialSession()
    private lazy var server = ControlServer(session: session, port: 8765)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
        server.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        session.disconnect()
    }
}
