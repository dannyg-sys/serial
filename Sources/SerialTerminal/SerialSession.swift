import Foundation
import SwiftUI

/// Shared, observable state bridging the serial port, the SwiftUI GUI (a SwiftTerm
/// terminal view), and the HTTP control server. UI-facing properties are published
/// on the main thread; the received-byte buffer and connection state are guarded by
/// locks so the control server and the serial IO queue can touch them from any thread.
final class SerialSession: ObservableObject {
    // UI-facing state (always mutated on main).
    @Published var availablePorts: [String] = []
    @Published var selectedPort: String = ""
    @Published var settings = SerialSettings()
    @Published var isConnected = false
    @Published var connectedPort: String? = nil
    @Published var lastError: String? = nil
    @Published var rxBytes: Int = 0
    @Published var txBytes: Int = 0
    @Published var localEcho: Bool = false     // device usually echoes; off avoids doubles
    @Published var httpPort: UInt16 = 8765
    @Published var connectionLabel: String = "" // e.g. "ssh pos_scangle · /dev/ttyUSB0"; drives window title
    @Published var connectionIsSerial = false   // true for local serial (enables Send Size / Auto)
    @Published var termCols: Int = 80          // live emulator size (from SwiftTerm)
    @Published var termRows: Int = 24
    @Published var autoSyncSize: Bool = true   // auto-send stty size on connect/resize

    /// Reads the emulator's live size (set by the terminal view). Preferred over the
    /// cached termCols/termRows, which can lag the first resize callback.
    var currentTermSize: (() -> (cols: Int, rows: Int))?

    // Terminal sinks — set by the terminal view. Always invoked on the main thread.
    var onFeedBytes: ((Data) -> Void)?         // raw device bytes → VT emulator
    var onFeedText: ((String) -> Void)?        // local banners (connect/disconnect…)
    var onClear: (() -> Void)?                 // reset the terminal

    private var transport: Transport?
    private let portLock = NSLock()

    // Received-byte ring buffer with a monotonic offset for incremental /read.
    private let bufLock = NSLock()
    private var rxBuffer: [UInt8] = []
    private var baseOffset: Int = 0            // bytes discarded off the front
    private let maxBuffer = 1_048_576          // keep last 1 MiB for the API

    // Authoritative connection state, updated synchronously (unlike the @Published
    // mirrors above, which hop to the main thread). The HTTP API reads these so a
    // status/write immediately after connect sees the real state, not a stale one.
    private let stateLock = NSLock()
    private var _connected = false
    private var _connSettings = SerialSettings()
    private var _connKind = "none"             // "serial" | "ssh" | "none"
    private var _connLabel = ""
    private var _connPort: String? = nil       // serial device path (nil for ssh)
    private var _connHost: String? = nil       // ssh host (nil for serial)
    private var _needsManualWinSize = true
    private var authTxBytes = 0

    struct StatusSnapshot {
        var connected: Bool
        var kind: String
        var label: String
        var port: String?
        var host: String?
        var settings: SerialSettings
        var rxBytes: Int
        var txBytes: Int
    }

    /// Thread-safe, always-current connection status for the control API.
    func statusSnapshot() -> StatusSnapshot {
        stateLock.lock()
        let snap = StatusSnapshot(connected: _connected, kind: _connKind, label: _connLabel,
                                  port: _connPort, host: _connHost, settings: _connSettings,
                                  rxBytes: totalReceived(), txBytes: authTxBytes)
        stateLock.unlock()
        return snap
    }

    /// Authoritative "is the connection open right now?" for API guards.
    var connectedNow: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _connected
    }

    init() {
        refreshPorts()
    }

    // MARK: - Ports

    func refreshPorts() {
        let ports = SerialPort.availablePorts()
        onMain {
            self.availablePorts = ports
            if self.selectedPort.isEmpty, let first = ports.first {
                self.selectedPort = first
            }
        }
    }

    // MARK: - Connect / disconnect / reconfigure

    /// Convenience for a local serial connection (used by the GUI).
    func connect(port path: String, settings newSettings: SerialSettings) throws {
        try connect(.serial(path: path, settings: newSettings))
    }

    /// Open any transport described by `spec`. Throws on failure; any thread.
    func connect(_ spec: ConnectionSpec) throws {
        portLock.lock()
        defer { portLock.unlock() }

        // Replace any existing connection.
        if let old = transport { old.close(); transport = nil }

        let t = makeTransport(spec)
        t.onData = { [weak self] data in self?.handleReceived(data) }
        t.onClosed = { [weak self] reason in self?.handlePortClosed(reason) }
        try t.open()
        transport = t

        bufLock.lock()
        rxBuffer.removeAll(keepingCapacity: true)
        baseOffset = 0
        bufLock.unlock()

        // Serial-specific settings/port; ssh host; common label.
        var newSettings = _connSettings
        var portPath: String? = nil
        var host: String? = nil
        switch spec {
        case .serial(let path, let s): newSettings = s; portPath = path
        case .ssh(let p): newSettings.baud = p.baud; host = p.host
        }

        stateLock.lock()
        _connected = true
        _connKind = spec.kind
        _connLabel = t.label
        _connPort = portPath
        _connHost = host
        _connSettings = newSettings
        _needsManualWinSize = t.needsManualWindowSize
        authTxBytes = 0
        stateLock.unlock()

        let label = t.label
        let manualWin = t.needsManualWindowSize
        let isSerial = spec.kind == "serial"
        onMain {
            self.settings = newSettings
            if let portPath { self.selectedPort = portPath }
            self.connectedPort = portPath ?? host
            self.isConnected = true
            self.lastError = nil
            self.rxBytes = 0
            self.txBytes = 0
            self.connectionLabel = label
            self.connectionIsSerial = isSerial
            self.feedText("[ connected \(label) ]")
        }

        // Serial links carry no window-size signal — push it via stty once things
        // settle. SSH negotiates its PTY size itself, so skip it there.
        if autoSyncSize && manualWin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.connectedNow, self.autoSyncSize else { return }
                self.sendWindowSize()
            }
        }
    }

    private func makeTransport(_ spec: ConnectionSpec) -> Transport {
        switch spec {
        case .serial(let path, let s):
            return SerialTransport(path: path, settings: s)
        case .ssh(let p):
            return SSHTransport(params: p, windowSize: { [weak self] in
                (cols: self?.termCols ?? 80, rows: self?.termRows ?? 24)
            })
        }
    }

    func disconnect() {
        portLock.lock()
        transport?.close()
        transport = nil
        portLock.unlock()
        stateLock.lock()
        _connected = false; _connKind = "none"; _connLabel = ""
        _connPort = nil; _connHost = nil
        stateLock.unlock()
        onMain {
            self.isConnected = false
            self.connectedPort = nil
            self.connectionLabel = ""
            self.connectionIsSerial = false
            self.feedText("[ disconnected ]")
        }
    }

    /// Change parameters on the live connection (no drop). Serial only.
    func reconfigure(_ newSettings: SerialSettings) throws {
        portLock.lock()
        defer { portLock.unlock() }
        guard let t = transport, t.supportsLineSettings else { return }
        try t.reconfigure(newSettings)
        stateLock.lock(); _connSettings = newSettings; _connLabel = t.label; stateLock.unlock()
        onMain {
            self.settings = newSettings
            self.feedText("[ reconfigured @ \(newSettings.baud) ]")
        }
    }

    // MARK: - Send

    /// Write raw bytes to the transport and (optionally) echo them into the terminal.
    @discardableResult
    func send(_ data: Data) throws -> Int {
        portLock.lock()
        defer { portLock.unlock() }
        guard let t = transport else { throw SerialError.notOpen }
        let n = try t.write(data)
        stateLock.lock(); authTxBytes += n; stateLock.unlock()
        onMain {
            self.txBytes += n
            if self.localEcho { self.onFeedBytes?(data) }
        }
        return n
    }

    // MARK: - Received data / incremental read for the API

    private func handleReceived(_ data: Data) {
        bufLock.lock()
        rxBuffer.append(contentsOf: data)
        if rxBuffer.count > maxBuffer {
            let drop = rxBuffer.count - maxBuffer
            rxBuffer.removeFirst(drop)
            baseOffset += drop
        }
        bufLock.unlock()

        onMain {
            self.rxBytes += data.count
            self.onFeedBytes?(data)
        }
    }

    private func handlePortClosed(_ reason: String?) {
        stateLock.lock(); _connected = false; _connPort = nil; stateLock.unlock()
        onMain {
            self.isConnected = false
            self.connectedPort = nil
            self.connectionLabel = ""
            self.connectionIsSerial = false
            self.lastError = reason
            self.feedText("[ port closed\(reason.map { ": \($0)" } ?? "") ]")
        }
    }

    /// Total bytes ever received (the high-water offset).
    func totalReceived() -> Int {
        bufLock.lock(); defer { bufLock.unlock() }
        return baseOffset + rxBuffer.count
    }

    /// Return received bytes starting at `offset`. Clamps offsets that have
    /// scrolled out of the retained window up to the current base.
    func read(fromOffset offset: Int) -> (base: Int, next: Int, data: Data) {
        bufLock.lock(); defer { bufLock.unlock() }
        let total = baseOffset + rxBuffer.count
        let start = max(offset, baseOffset)
        let idx = start - baseOffset
        let slice = (idx >= 0 && idx <= rxBuffer.count) ? Array(rxBuffer[idx...]) : []
        return (base: baseOffset, next: total, data: Data(slice))
    }

    // MARK: - Terminal helpers

    func clearTerminal() {
        onMain { self.onClear?() }
    }

    /// Record the emulator's current size (called by the terminal on resize).
    func updateTermSize(cols: Int, rows: Int) {
        onMain { self.termCols = cols; self.termRows = rows }
    }

    /// Push the terminal size to the remote TTY so line-wrapping / readline / TUIs
    /// match. Serial has no in-band window-size signal, so we send an `stty` command.
    /// Uses the emulator's *live* size, and a leading space so shells with
    /// HISTCONTROL=ignorespace keep it out of history.
    func sendWindowSize() {
        guard connectedNow else { return }
        stateLock.lock(); let manual = _needsManualWinSize; stateLock.unlock()
        guard manual else { return }   // SSH negotiates its own PTY size
        let size = currentTermSize?() ?? (cols: termCols, rows: termRows)
        onMain { self.termCols = size.cols; self.termRows = size.rows }
        let cmd = " stty rows \(size.rows) cols \(size.cols)\n"
        _ = try? send(Data(cmd.utf8))
    }

    /// Feed a local status line into the terminal, on its own line, dimmed.
    private func feedText(_ s: String) {
        // \r\n keeps it on a fresh line; \u{1b}[2m…\u{1b}[0m dims it.
        onFeedText?("\r\n\u{1b}[2m\(s)\u{1b}[0m\r\n")
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
