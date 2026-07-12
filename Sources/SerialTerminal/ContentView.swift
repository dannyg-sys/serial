import SwiftUI

struct ContentView: View {
    @EnvironmentObject var session: SerialSession
    @State private var showOpen = false
    @State private var showAttach = false

    // Matches SwiftTerm's nativeBackgroundColor so the inset margin blends in.
    static let terminalBackground = Color(.sRGB, red: 0.07, green: 0.08, blue: 0.11, opacity: 1)

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            SwiftTermView(session: session)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Self.terminalBackground)
                .frame(minWidth: 640, minHeight: 360)
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 440)
        .navigationTitle(session.connectionLabel.isEmpty
                         ? "Serial Terminal — not connected"
                         : session.connectionLabel)
        .sheet(isPresented: $showOpen) {
            OpenConnectionSheet().environmentObject(session)
        }
        .sheet(isPresented: $showAttach) {
            AttachDeviceSheet().environmentObject(session)
        }
        .onAppear {
            // Prompt for a connection on launch if nothing is open.
            if !session.isConnected { showOpen = true }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button {
                showOpen = true
            } label: {
                Label("Open Connection…", systemImage: "cable.connector")
            }
            .help("Choose a USB / Network (SSH) / Bluetooth connection")

            if session.isConnected {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text(session.connectionLabel)
                    .font(.system(.body, design: .monospaced)).lineLimit(1)
            } else {
                Text("Not connected").foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Echo", isOn: $session.localEcho)
                .toggleStyle(.checkbox)
                .help("Echo typed characters locally (enable if the far end doesn't echo)")

            if session.isConnected && session.connectionIsSerial {
                Button("Send Size") { session.sendWindowSize() }
                    .help("Send `stty rows \(session.termRows) cols \(session.termCols)` to match this window")
                Toggle("Auto", isOn: $session.autoSyncSize)
                    .toggleStyle(.checkbox)
                    .help("Auto-send the terminal size on connect/resize")
            }

            if session.isConnected && !session.connectionIsSerial {
                Button("Attach Device…") { showAttach = true }
                    .help("Discover and bridge a serial device on the connected SSH host")
            }

            Button("Clear") { session.clearTerminal() }

            if session.isConnected {
                Button("Disconnect") { session.disconnect() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle().fill(session.isConnected ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text(session.isConnected ? "Connected \(session.connectedPort ?? "")" : "Disconnected")
            Text("RX \(session.rxBytes)  TX \(session.txBytes)").foregroundStyle(.secondary)
            Text("\(session.termCols)×\(session.termRows)").foregroundStyle(.secondary)
            if session.isConnected { Text("· click terminal & type").foregroundStyle(.secondary) }
            if let e = session.lastError { Text(e).foregroundStyle(.red).lineLimit(1) }
            Spacer()
            Text("API 127.0.0.1:\(String(session.httpPort))").foregroundStyle(.secondary)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Accept "115200", "1500000", "1_500_000", "1,500,000", "1500k", "1.5M".
    static func parseBaud(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: ",", with: "")
             .replacingOccurrences(of: "_", with: "")
             .replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        var mult = 1.0
        if s.hasSuffix("m") { mult = 1_000_000; s.removeLast() }
        else if s.hasSuffix("k") { mult = 1_000; s.removeLast() }
        guard let v = Double(s), v > 0 else { return nil }
        return Int((v * mult).rounded())
    }
}
