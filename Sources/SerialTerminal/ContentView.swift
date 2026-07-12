import SwiftUI

private let baudPresets = [300, 1200, 2400, 4800, 9600, 19200, 38400,
                          57600, 115200, 230400, 460800, 921600, 1500000, 3000000]

struct ContentView: View {
    @EnvironmentObject var session: SerialSession
    @State private var customBaud = ""

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            SwiftTermView(session: session)
                .frame(minWidth: 640, minHeight: 360)
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { customBaud = String(session.settings.baud) }
        .onChange(of: session.settings.baud) { newValue in
            let typed = Self.parseBaud(customBaud)
            if typed != newValue { customBaud = String(newValue) }
        }
    }

    // MARK: - Top controls

    private var controlBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Port", selection: $session.selectedPort) {
                    if session.availablePorts.isEmpty {
                        Text("— no ports —").tag("")
                    }
                    ForEach(session.availablePorts, id: \.self) { p in
                        Text(p.replacingOccurrences(of: "/dev/", with: "")).tag(p)
                    }
                }
                .frame(minWidth: 220)
                .disabled(session.isConnected)

                Button { session.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan serial ports")
                    .disabled(session.isConnected)

                Spacer()

                Button(session.isConnected ? "Disconnect" : "Connect") { toggleConnection() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedPort.isEmpty && !session.isConnected)
            }

            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Text("Baud")
                    TextField("baud", text: $customBaud)
                        .frame(width: 88)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .onSubmit(applyTypedBaud)
                        .help("Any rate — e.g. 115200, 1500000, 1.5M, 1500k")
                    Menu {
                        ForEach(baudPresets, id: \.self) { b in
                            Button(String(b)) { customBaud = String(b); applyTypedBaud() }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                }

                Picker("Data", selection: intBinding(\.dataBits)) {
                    ForEach([5, 6, 7, 8], id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 90)

                Picker("Parity", selection: parityBinding) {
                    ForEach(Parity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.frame(width: 120)

                Picker("Stop", selection: intBinding(\.stopBits)) {
                    ForEach([1, 2], id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 80)

                Spacer()

                Toggle("Echo", isOn: $session.localEcho)
                    .toggleStyle(.checkbox)
                    .help("Echo typed characters locally (enable if the device does not echo)")

                Button("Send Size") { session.sendWindowSize() }
                    .disabled(!session.isConnected)
                    .help("Send `stty rows \(session.termRows) cols \(session.termCols)` "
                        + "so the remote TTY matches this window (fixes readline / TUI wrapping)")

                Toggle("Auto", isOn: $session.autoSyncSize)
                    .toggleStyle(.checkbox)
                    .help("Automatically send the terminal size on connect and on resize. "
                        + "Turn off for non-shell devices (MCUs) that shouldn't receive stty.")

                Button("Clear") { session.clearTerminal() }
            }
        }
        .padding(8)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.isConnected ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text(session.isConnected ? "Connected \(session.connectedPort ?? "")" : "Disconnected")
            Text("RX \(session.rxBytes)  TX \(session.txBytes)").foregroundStyle(.secondary)
            Text("\(session.termCols)×\(session.termRows)").foregroundStyle(.secondary)
            if session.isConnected {
                Text("· click terminal & type").foregroundStyle(.secondary)
            }
            if let e = session.lastError {
                Text(e).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Text("API 127.0.0.1:\(String(session.httpPort))").foregroundStyle(.secondary)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func toggleConnection() {
        if session.isConnected {
            session.disconnect()
        } else {
            applyTypedBaud()
            do {
                try session.connect(port: session.selectedPort, settings: session.settings)
            } catch {
                session.lastError = "\(error)"
            }
        }
    }

    private func applyTypedBaud() {
        if let b = Self.parseBaud(customBaud), b > 0 {
            session.settings.baud = b
            customBaud = String(b)
            liveReconfigure()
        } else {
            customBaud = String(session.settings.baud)
        }
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

    private func liveReconfigure() {
        guard session.isConnected else { return }
        try? session.reconfigure(session.settings)
    }

    private var parityBinding: Binding<Parity> {
        Binding(get: { session.settings.parity },
                set: { session.settings.parity = $0; liveReconfigure() })
    }
    private func intBinding(_ kp: WritableKeyPath<SerialSettings, Int>) -> Binding<Int> {
        Binding(get: { session.settings[keyPath: kp] },
                set: { session.settings[keyPath: kp] = $0; liveReconfigure() })
    }
}
