import Foundation
import Darwin
import SwiftTerm

/// A byte pipe the session can read from and write to, regardless of whether it
/// is a local serial port, an SSH session, or (later) a raw TCP / RFC2217 link.
/// The session only ever deals in bytes, so every backend looks the same to it.
protocol Transport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onClosed: ((String?) -> Void)? { get set }
    var isOpen: Bool { get }

    /// Whether baud/data/parity/stop controls are meaningful for this backend.
    var supportsLineSettings: Bool { get }
    /// Whether the remote TTY size must be pushed via `stty` (serial) or is
    /// negotiated by the transport itself (SSH PTY).
    var needsManualWindowSize: Bool { get }
    /// Human-readable label for the status bar / API.
    var label: String { get }

    func open() throws
    @discardableResult func write(_ data: Data) throws -> Int
    func reconfigure(_ settings: SerialSettings) throws
    func close()

    /// Probe the far end for serial devices + socat (SSH only). Completion on main.
    func discoverSerialDevices(completion: @escaping (RemoteScan) -> Void)
}

extension Transport {
    func discoverSerialDevices(completion: @escaping (RemoteScan) -> Void) {
        completion(RemoteScan(devices: [], hasSocat: false))
    }
}

/// How to establish a connection. Built by the GUI or the HTTP API, consumed by
/// `SerialSession.connect`.
/// Result of probing a remote host for serial devices.
struct RemoteScan {
    var devices: [String]
    var hasSocat: Bool
}

enum ConnectionSpec {
    case serial(path: String, settings: SerialSettings)
    case ssh(SSHParams)
    case hid(HIDParams)

    var kind: String {
        switch self {
        case .serial: return "serial"
        case .ssh:    return "ssh"
        case .hid:    return "hid"
        }
    }
}

struct SSHParams: Equatable {
    var host: String = ""              // "user@host", or an ~/.ssh/config alias
    var attachDevice: Bool = false     // false = interactive shell; true = bridge a serial device
    var devicePath: String = "/dev/ttyUSB0"
    var baud: Int = 9600
    var customCommand: String = ""     // if set, overrides the generated remote command
}

// MARK: - Local serial (termios) backend

/// Wraps the low-level `SerialPort` as a `Transport`.
final class SerialTransport: Transport {
    private let port = SerialPort()
    private let path: String
    private var settings: SerialSettings

    init(path: String, settings: SerialSettings) {
        self.path = path
        self.settings = settings
    }

    var onData: ((Data) -> Void)? {
        get { port.onData } set { port.onData = newValue }
    }
    var onClosed: ((String?) -> Void)? {
        get { port.onClosed } set { port.onClosed = newValue }
    }
    var isOpen: Bool { port.isOpen }
    var supportsLineSettings: Bool { true }
    var needsManualWindowSize: Bool { true }
    var label: String {
        let p = settings.parity.rawValue.prefix(1).uppercased()
        return "\(path) @ \(settings.baud) \(settings.dataBits)\(p)\(settings.stopBits)"
    }

    func open() throws { try port.open(path: path, settings: settings) }
    @discardableResult func write(_ data: Data) throws -> Int { try port.write(data) }
    func reconfigure(_ s: SerialSettings) throws {
        settings = s
        try port.reconfigure(settings: s)
    }
    func close() { port.close() }
}

// MARK: - SSH backend (system ssh in a PTY, via SwiftTerm LocalProcess)

/// Runs the operating system `ssh` inside a pseudo-terminal. Reuses the user's
/// ~/.ssh/config, keys, agent, known_hosts, and inline password/2FA prompts.
/// Either drops into a remote shell, or bridges a remote serial device.
final class SSHTransport: NSObject, Transport, LocalProcessDelegate {
    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    private var process: LocalProcess?
    private let params: SSHParams
    private let windowSize: () -> (cols: Int, rows: Int)
    private(set) var isOpen = false

    var supportsLineSettings: Bool { false }
    var needsManualWindowSize: Bool { false }   // SSH negotiates the PTY size itself
    var label: String {
        params.attachDevice
            ? "ssh \(params.host) · \(params.devicePath)@\(params.baud)"
            : "ssh \(params.host)"
    }

    init(params: SSHParams, windowSize: @escaping () -> (cols: Int, rows: Int)) {
        self.params = params
        self.windowSize = windowSize
    }

    func open() throws {
        guard !params.host.isEmpty else { throw SerialError.notOpen }
        let lp = LocalProcess(delegate: self)

        // -tt forces a PTY even with a remote command; timeouts keep dead boxes
        // from hanging the connect and drop stale links on the fleet.
        var args = ["-tt",
                    "-o", "ConnectTimeout=15",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3"]
        args.append(params.host)
        let remote = remoteCommand()
        if !remote.isEmpty { args.append(contentsOf: ["--", remote]) }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        lp.startProcess(executable: "/usr/bin/ssh", args: args, environment: envArray)
        process = lp
        isOpen = true
    }

    @discardableResult func write(_ data: Data) throws -> Int {
        guard isOpen, let p = process else { throw SerialError.notOpen }
        p.send(data: ArraySlice(data))
        return data.count
    }

    func reconfigure(_ settings: SerialSettings) throws { /* not applicable to SSH */ }

    func close() {
        process?.terminate()
        process = nil
        isOpen = false
    }

    /// The command to run on the remote host (empty = interactive login shell).
    private func remoteCommand() -> String {
        if !params.customCommand.isEmpty { return params.customCommand }
        guard params.attachDevice else { return "" }
        return Self.bridgeCommand(dev: params.devicePath, baud: params.baud)
    }

    /// Single-line bridge to run *inside* the existing remote shell. Portable:
    /// `stty … < dev` configures the line on both Linux and macOS/BSD (no `-F`),
    /// prefers `socat`, and falls back to a `cat`-based bridge when socat is
    /// missing. Ctrl-C returns to the shell.
    static func inShellBridge(dev: String, baud: Int) -> String {
        "stty \(baud) raw -echo < \(dev) 2>/dev/null; "
        + "if command -v socat >/dev/null 2>&1; then socat -,raw,echo=0 \(dev),b\(baud),raw,echo=0; "
        + "else cat \(dev) & __c=$!; cat > \(dev); kill $__c 2>/dev/null; fi"
    }

    /// Out-of-band device discovery: a separate non-interactive `ssh host find …`.
    /// Avoids the interactive shell's aliases (colorized `ls`), globbing quirks,
    /// and PTY line-wrap mangling — `find` returns clean full paths on any shell.
    func discoverSerialDevices(completion: @escaping (RemoteScan) -> Void) {
        let host = params.host
        // Real serial adapters only (usbserial/usbmodem/ttyUSB/ttyACM/ttyAMA and
        // all /dev/serial/by-id symlinks) — skip cu.Bluetooth/debug-console noise.
        // Also report whether `socat` is available on the host.
        let cmd = "find /dev/serial/by-id -maxdepth 1 -type l 2>/dev/null; "
            + "find /dev -maxdepth 1 \\( -name 'ttyUSB*' -o -name 'ttyACM*' -o -name 'ttyAMA*' "
            + "-o -name 'cu.usb*' -o -name 'tty.usb*' \\) 2>/dev/null; "
            + "command -v socat >/dev/null 2>&1 && echo __HAS_SOCAT__"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                           "-o", "StrictHostKeyChecking=accept-new", host, cmd]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(RemoteScan(devices: [], hasSocat: false)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                if p.isRunning { p.terminate() }
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var seen = Set<String>(); var devs: [String] = []; var hasSocat = false
            for line in String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let d = line.trimmingCharacters(in: .whitespaces)
                if d == "__HAS_SOCAT__" { hasSocat = true; continue }
                if d.hasPrefix("/dev/"), !seen.contains(d) { seen.insert(d); devs.append(d) }
            }
            let scan = RemoteScan(devices: devs, hasSocat: hasSocat)
            DispatchQueue.main.async { completion(scan) }
        }
    }

    /// Configure the remote line, then bridge stdio <-> device. Prefers `socat`;
    /// falls back to `stty` + `cat` if socat isn't installed.
    static func bridgeCommand(dev: String, baud: Int) -> String {
        "stty -F \(dev) \(baud) raw -echo -echoe -echok -echoctl -echoke 2>/dev/null; "
        + "if command -v socat >/dev/null 2>&1; then "
        + "exec socat -,raw,echo=0 \(dev),b\(baud),raw,echo=0; "
        + "else cat \(dev) & CATPID=$!; cat > \(dev); kill $CATPID 2>/dev/null; fi"
    }

    // MARK: LocalProcessDelegate
    func dataReceived(slice: ArraySlice<UInt8>) { onData?(Data(slice)) }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        isOpen = false
        onClosed?(exitCode.map { "ssh exited (code \($0))" } ?? "ssh exited")
    }

    func getWindowSize() -> winsize {
        let (cols, rows) = windowSize()
        return winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}
