import SwiftUI

/// Modal "Open Connection" dialog: a category sidebar (USB / Network / Bluetooth /
/// Other) with a device list, mirroring the familiar macOS serial-app pattern.
struct OpenConnectionSheet: View {
    @EnvironmentObject var session: SerialSession
    @Environment(\.dismiss) private var dismiss

    enum Category: String, CaseIterable, Identifiable {
        case usb = "USB", network = "Network", bluetooth = "Bluetooth", other = "Other"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .usb: return "cable.connector"
            case .network: return "globe"
            case .bluetooth: return "wave.3.right"
            case .other: return "app.connected.to.app.below.fill"
            }
        }
    }

    @State private var category: Category = .usb
    @State private var ports: [String] = []
    @State private var sshHosts: [SSHConfig.HostEntry] = []
    @State private var hostFilter = ""

    @State private var selectedPort: String?
    @State private var selectedHost: String?

    // Serial line settings.
    @State private var baud = "9600"
    @State private var dataBits = 8
    @State private var parity: Parity = .none
    @State private var stopBits = 1

    // SSH device-attach options.
    @State private var sshAttach = false
    @State private var sshDevice = "/dev/ttyUSB0"
    @State private var sshBaud = "9600"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                rightPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 470)
        .onAppear(perform: load)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $category) {
                Section("Devices") {
                    ForEach(Category.allCases) { c in
                        Label(c.rawValue, systemImage: c.icon).tag(c)
                    }
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 6) {
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan")
                Spacer()
            }
            .padding(6)
        }
        .frame(width: 190)
    }

    // MARK: - Right pane

    @ViewBuilder private var rightPane: some View {
        switch category {
        case .network: networkPane
        default: serialPane
        }
    }

    /// Pseudo-port for the BLE HID keyboard bridge (listed under Bluetooth).
    private static let hidEntry = "hid://t-dongle"

    private var serialPane: some View {
        var list = ports.filter { categoryOf($0) == category }
        if category == .bluetooth { list.insert(Self.hidEntry, at: 0) }
        return VStack(alignment: .leading, spacing: 0) {
            if list.isEmpty {
                centeredEmpty("No Devices Available")
            } else {
                List(list, id: \.self, selection: $selectedPort) { p in
                    if p == Self.hidEntry {
                        Label("T-Dongle HID bridge — type into a TV / headless box",
                              systemImage: "keyboard")
                            .tag(p)
                    } else {
                        Label(p.replacingOccurrences(of: "/dev/", with: ""),
                              systemImage: "cable.connector")
                            .tag(p)
                    }
                }
                Divider()
                if selectedPort == Self.hidEntry {
                    Text("Finds the dongle over Bluetooth. What you type in the terminal is "
                         + "typed as a USB keyboard on the device it is plugged into.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    settingsRow
                }
            }
        }
    }

    private var settingsRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Text("Baud")
                TextField("9600", text: $baud).frame(width: 84)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                Menu {
                    ForEach([9600, 19200, 38400, 57600, 115200, 230400, 921600, 1500000], id: \.self) { b in
                        Button(String(b)) { baud = String(b) }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuIndicator(.hidden).frame(width: 24)
            }
            Picker("Data", selection: $dataBits) { ForEach([5,6,7,8], id: \.self) { Text("\($0)").tag($0) } }
                .frame(width: 86)
            Picker("Par", selection: $parity) {
                ForEach(Parity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.frame(width: 110)
            Picker("Stop", selection: $stopBits) { ForEach([1,2], id: \.self) { Text("\($0)").tag($0) } }
                .frame(width: 72)
            Spacer()
        }
        .padding(10)
    }

    private var networkPane: some View {
        let hosts = filteredHosts
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter ~/.ssh/config hosts (e.g. tora)", text: $hostFilter)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            Divider()

            if hosts.isEmpty {
                centeredEmpty(sshHosts.isEmpty ? "No ~/.ssh/config Hosts" : "No Matching Hosts")
            } else {
                List(hosts, id: \.alias, selection: $selectedHost) { h in
                    HStack {
                        Label(h.alias, systemImage: "server.rack")
                        if let s = h.subtitle {
                            Text(s).foregroundStyle(.secondary).font(.caption)
                        }
                    }.tag(h.alias)
                }
            }

            Divider()
            HStack(spacing: 10) {
                Toggle("Attach serial device", isOn: $sshAttach)
                    .toggleStyle(.checkbox)
                    .help("Bridge a remote serial device (e.g. a scale) instead of a login shell")
                if sshAttach {
                    HStack(spacing: 2) {
                        Text("Dev")
                        TextField("/dev/ttyUSB0", text: $sshDevice).frame(width: 130)
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack(spacing: 2) {
                        Text("Baud")
                        TextField("9600", text: $sshBaud).frame(width: 74)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }
                Spacer()
            }
            .padding(10)
        }
    }

    private func centeredEmpty(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(.title3).foregroundStyle(.secondary); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Open") { open() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canOpen)
        }
        .padding(12)
    }

    // MARK: - Logic

    private var filteredHosts: [SSHConfig.HostEntry] {
        let q = hostFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sshHosts }
        return sshHosts.filter {
            $0.alias.localizedCaseInsensitiveContains(q)
                || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var canOpen: Bool {
        switch category {
        case .network:
            return selectedHost != nil || !hostFilter.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return selectedPort != nil
        }
    }

    private func categoryOf(_ path: String) -> Category {
        let n = path.lowercased()
        if n.contains("bluetooth") { return .bluetooth }
        if n.contains("usbserial") || n.contains("usbmodem") || n.contains("usbto")
            || n.contains("wchusb") || n.contains("slab") { return .usb }
        return .other
    }

    private func load() {
        ports = SerialPort.availablePorts()
        sshHosts = SSHConfig.discoverHosts()
        baud = String(session.settings.baud)
    }

    private func open() {
        do {
            switch category {
            case .network:
                var p = SSHParams()
                p.host = (selectedHost ?? hostFilter).trimmingCharacters(in: .whitespaces)
                p.attachDevice = sshAttach
                p.devicePath = sshDevice.trimmingCharacters(in: .whitespaces)
                p.baud = ContentView.parseBaud(sshBaud) ?? 9600
                guard !p.host.isEmpty else { return }
                try session.connect(.ssh(p))
            default:
                guard let path = selectedPort else { return }
                if path == Self.hidEntry {
                    try session.connect(.hid(HIDParams()))
                    dismiss()
                    return
                }
                let s = SerialSettings(baud: ContentView.parseBaud(baud) ?? 9600,
                                       dataBits: dataBits, parity: parity, stopBits: stopBits)
                try session.connect(.serial(path: path, settings: s))
            }
            dismiss()
        } catch {
            session.lastError = "\(error)"
        }
    }
}
