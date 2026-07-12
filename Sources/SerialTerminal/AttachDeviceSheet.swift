import SwiftUI

/// Shown from an SSH shell session: discover the remote host's serial devices
/// and bridge the chosen one into the terminal (Ctrl-C returns to the shell).
struct AttachDeviceSheet: View {
    @EnvironmentObject var session: SerialSession
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [String] = []
    @State private var device = "/dev/ttyUSB0"
    @State private var baud = "9600"
    @State private var scanning = false
    @State private var scanned = false
    @State private var hasSocat = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach Remote Serial Device").font(.headline)
            Text("Runs on the connected SSH host and bridges the device into this "
                 + "terminal. Press Ctrl-C in the terminal to return to the shell.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("Device").frame(width: 52, alignment: .leading)
                TextField("/dev/ttyUSB0", text: $device)
                    .font(.system(.body, design: .monospaced))
                Menu {
                    if devices.isEmpty {
                        Text(scanned ? "none found" : "not scanned")
                    }
                    ForEach(devices, id: \.self) { d in Button(d) { device = d } }
                } label: { Image(systemName: "chevron.down") }
                .menuIndicator(.hidden).frame(width: 26)
                Button(scanning ? "Scanning…" : "List") { discover() }
                    .disabled(scanning || !session.isConnected)
            }

            HStack(spacing: 6) {
                Text("Baud").frame(width: 52, alignment: .leading)
                TextField("9600", text: $baud)
                    .frame(width: 100).font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                Menu {
                    ForEach([9600, 19200, 38400, 57600, 115200], id: \.self) { b in
                        Button(String(b)) { baud = String(b) }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuIndicator(.hidden).frame(width: 26)
                Spacer()
            }

            if scanned && devices.isEmpty {
                Text("No serial adapters found (ttyUSB*/ttyACM*/serial-by-id on Linux, "
                     + "cu.usb*/tty.usb* on macOS).")
                    .font(.caption).foregroundStyle(.orange)
            }
            if scanned && !hasSocat {
                Label("socat not found on the host — will bridge with `cat` "
                      + "(read works; install socat for full raw I/O).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") { attach() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(device.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear { discover() }
    }

    private func discover() {
        guard session.isConnected else { return }
        scanning = true
        session.listRemoteDevices { scan in
            devices = scan.devices
            hasSocat = scan.hasSocat
            scanning = false
            scanned = true
            if let first = scan.devices.first { device = first }
        }
    }

    private func attach() {
        let dev = device.trimmingCharacters(in: .whitespaces)
        session.attachRemoteDevice(dev: dev, baud: ContentView.parseBaud(baud) ?? 9600)
        dismiss()
    }
}
