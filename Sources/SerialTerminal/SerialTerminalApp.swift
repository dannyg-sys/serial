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
            RootView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// Per-window root. Each window creates its own session + control server, so
/// windows are fully independent connections (File ▸ New Window = Cmd-N).
struct RootView: View {
    @StateObject private var host = WindowHost()
    var body: some View {
        ContentView().environmentObject(host.session)
    }
}

/// Owns one window's session and its control server; frees the port on close.
final class WindowHost: ObservableObject {
    let session: SerialSession
    let port: UInt16
    private let server: ControlServer

    init() {
        let p = SessionRegistry.shared.allocatePort()
        let s = SerialSession()
        s.httpPort = p
        session = s
        port = p
        server = ControlServer(session: s, port: p)
        server.start()
        SessionRegistry.shared.register(port: p, session: s)
    }

    deinit {
        server.stop()
        session.disconnect()
        SessionRegistry.shared.unregister(port: port)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }
}
