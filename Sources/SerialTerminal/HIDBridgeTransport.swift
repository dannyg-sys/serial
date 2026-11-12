import Foundation
import CoreBluetooth
import IOKit

/// Parameters for the HID keyboard bridge: a LilyGO T-Dongle-S3 running the
/// t-dongle-hid-bridge firmware (BLE Nordic-UART in, USB HID keyboard out).
/// Whatever is written to this transport is typed on the device the dongle is
/// plugged into.
struct HIDParams: Equatable {
    var name: String = ""      // optional: only link to a dongle advertising this name
}

/// One message of the dongle protocol (first byte = opcode).
enum HIDMessage: Equatable {
    case text(String)       // 'T'  type text
    case key(String)        // 'S'  special key: enter, tab, esc, up, down, …
    case combo(String)      // 'K'  e.g. "ctrl+c", "ctrl+alt+t"
    case config(String)     // 'C'  e.g. "delay=20", "layout=us"

    /// Special-key names the firmware understands.
    static let knownKeys: Set<String> = ["enter", "tab", "esc", "space", "backspace", "delete",
                                         "up", "down", "left", "right", "home", "end"]

    var wire: Data {
        switch self {
        case .text(let s):   return Data(("T" + s).utf8)
        case .key(let s):    return Data(("S" + s).utf8)
        case .combo(let s):  return Data(("K" + s).utf8)
        case .config(let s): return Data(("C" + s).utf8)
        }
    }

    /// What to show in the terminal once the dongle has confirmed the message.
    /// The dongle is write-only, so this echo is the only feedback there is.
    var echo: String {
        func dim(_ s: String) -> String { "\u{1b}[2m‹\(s)›\u{1b}[0m" }
        switch self {
        case .text(let s): return s
        case .key(let k):
            switch k {
            case "enter":     return "\r\n"
            case "tab":       return "\t"
            case "backspace": return "\u{8} \u{8}"
            default:          return dim(k)
            }
        case .combo(let c):  return dim(c)
        case .config(let c): return dim(c)
        }
    }
}

/// Turns the byte stream a terminal produces (printable text, CR, control
/// bytes, xterm escape sequences) into dongle messages.
enum HIDTranslator {
    static let maxText = 150            // payload bytes per text message

    static func translate(_ data: Data) -> [HIDMessage] {
        let b = [UInt8](data)
        var out: [HIDMessage] = []
        var run: [UInt8] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(.text(String(decoding: run, as: UTF8.self)))
            run.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < b.count {
            let c = b[i]
            switch c {
            case 0x20...0x7E:
                run.append(c)
                if run.count >= maxText { flush() }
                i += 1
            case 0x0D:                                  // CR (and CRLF) = Enter
                flush(); out.append(.key("enter")); i += 1
                if i < b.count, b[i] == 0x0A { i += 1 }
            case 0x0A:
                flush(); out.append(.key("enter")); i += 1
            case 0x09:
                flush(); out.append(.key("tab")); i += 1
            case 0x08, 0x7F:
                flush(); out.append(.key("backspace")); i += 1
            case 0x1B:
                flush()
                let (msg, used) = escape(b, at: i)
                if let msg { out.append(msg) }
                i += used
            case 0x01...0x1A:                           // Ctrl-A … Ctrl-Z
                flush()
                out.append(.combo("ctrl+\(Character(UnicodeScalar(c + 0x60)))"))
                i += 1
            default:
                i += 1      // NUL, other controls, non-ASCII: the firmware can't type them
            }
        }
        flush()
        return out
    }

    /// Decode the escape sequence starting at `i`. Returns the message (nil if
    /// the sequence has no keyboard equivalent) and how many bytes it consumed.
    private static func escape(_ b: [UInt8], at i: Int) -> (HIDMessage?, Int) {
        guard i + 1 < b.count else { return (.key("esc"), 1) }
        let next = b[i + 1]

        func cursor(_ final: UInt8) -> HIDMessage? {
            switch final {
            case 0x41: return .key("up")
            case 0x42: return .key("down")
            case 0x43: return .key("right")
            case 0x44: return .key("left")
            case 0x48: return .key("home")
            case 0x46: return .key("end")
            default:   return nil
            }
        }

        if next == 0x4F {                               // SS3: ESC O A
            guard i + 2 < b.count else { return (nil, 2) }
            return (cursor(b[i + 2]), 3)
        }
        if next == 0x5B {                               // CSI: ESC [ params final
            var j = i + 2
            var params: [UInt8] = []
            while j < b.count, (0x20...0x3F).contains(b[j]) { params.append(b[j]); j += 1 }
            guard j < b.count else { return (nil, b.count - i) }
            let final = b[j]
            let used = j - i + 1
            if final == 0x7E {                          // ESC [ n ~
                let n = Int(String(decoding: params, as: UTF8.self)
                    .split(separator: ";").first ?? "") ?? 0
                switch n {
                case 1, 7: return (.key("home"), used)
                case 4, 8: return (.key("end"), used)
                case 3:    return (.key("delete"), used)
                default:   return (nil, used)
                }
            }
            return (cursor(final), used)
        }
        if (0x21...0x7E).contains(next) {               // ESC x = Option/Alt + x
            return (.combo("alt+\(Character(UnicodeScalar(next)))"), 2)
        }
        return (.key("esc"), 1)
    }
}

// MARK: - BLE transport

/// Owns the single Bluetooth link to the dongle. Messages are sent one at a
/// time with acknowledged writes; the dongle notifies "ok" when it has finished
/// typing, and only then is the next message sent and the echo shown.
final class HIDBridgeTransport: NSObject, Transport, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // we write
    static let txUUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // dongle notifies

    var onData: ((Data) -> Void)?
    var onClosed: ((String?) -> Void)?

    var supportsLineSettings: Bool { false }
    var needsManualWindowSize: Bool { false }   // never type `stty …` into the target
    var label: String { "hid · " + (params.name.isEmpty ? "T-Dongle" : params.name) }

    private let params: HIDParams
    private let q = DispatchQueue(label: "hid.bridge")
    private let openLock = NSLock()
    private var _open = false
    var isOpen: Bool { openLock.lock(); defer { openLock.unlock() }; return _open }
    private func setOpen(_ v: Bool) { openLock.lock(); _open = v; openLock.unlock() }

    // Everything below is touched only on `q`.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var linked = false
    private var everLinked = false
    private var pending: [HIDMessage] = []
    private var inFlight: HIDMessage?
    private var ackTimer: DispatchWorkItem?
    private var scanTimer: DispatchWorkItem?
    private var lastDropNotice = Date.distantPast
    /// One enter per queued message, one leave when it is confirmed or dropped.
    private let work = DispatchGroup()

    init(params: HIDParams) { self.params = params }

    /// Whether the BLE link is up right now (safe from any thread but `q`).
    var isLinked: Bool { q.sync { linked } }

    // MARK: Transport

    func open() throws {
        setOpen(true)
        q.async { [weak self] in
            guard let self else { return }
            self.emit("hid bridge: looking for the dongle…")
            self.central = CBCentralManager(delegate: self, queue: self.q)
        }
    }

    @discardableResult func write(_ data: Data) throws -> Int {
        guard isOpen else { throw SerialError.notOpen }
        enqueue(HIDTranslator.translate(data))
        return data.count
    }

    /// Send a key / combo / config message that has no terminal byte form.
    func send(_ message: HIDMessage) throws {
        guard isOpen else { throw SerialError.notOpen }
        enqueue([message])
    }

    // MARK: Feedback-loop guard

    /// True when an Espressif USB device (the dongle's USB side) is attached to
    /// this Mac. Then keys typed in our own window would be typed straight back
    /// into it by the dongle and loop forever.
    static func dongleAttachedToThisMac() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            return false
        }
        matching["idVendor"] = 0x303A                   // Espressif
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iter) }
        let dev = IOIteratorNext(iter)
        guard dev != 0 else { return false }
        IOObjectRelease(dev)
        return true
    }

    /// Called for keystrokes coming from the terminal view. Returns true (and
    /// says why in the terminal) when they must not be sent.
    func refuseKeyboardInput() -> Bool {
        guard Self.dongleAttachedToThisMac() else { return false }
        q.async { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastDropNotice) > 3 else { return }
            self.lastDropNotice = Date()
            self.emit("the dongle is plugged into this Mac, so typing here would be typed "
                      + "straight back into this window in a loop — plug it into the target device")
        }
        return true
    }

    /// Block until everything queued has been typed (false on timeout).
    func waitUntilIdle(timeout: TimeInterval) -> Bool {
        work.wait(timeout: .now() + timeout) == .success
    }

    func reconfigure(_ settings: SerialSettings) throws { /* not applicable */ }

    func close() {
        setOpen(false)
        q.async { [weak self] in self?.teardown() }
    }

    // MARK: Queue (all on q)

    private func enqueue(_ msgs: [HIDMessage]) {
        guard !msgs.isEmpty else { return }
        msgs.forEach { _ in work.enter() }
        q.async { [weak self] in
            guard let self else { return }
            // Once a link has been lost, don't hoard keystrokes for whatever the
            // dongle is plugged into next — drop them and say so.
            if !self.isOpen || (!self.linked && self.everLinked) {
                msgs.forEach { _ in self.work.leave() }
                if self.isOpen, Date().timeIntervalSince(self.lastDropNotice) > 2 {
                    self.lastDropNotice = Date()
                    self.emit("not linked — input dropped")
                }
                return
            }
            self.pending.append(contentsOf: msgs)
            self.pump()
        }
    }

    private func pump() {
        guard linked, inFlight == nil, let p = peripheral, let rx, !pending.isEmpty else { return }
        let m = pending.removeFirst()
        inFlight = m
        let wire = m.wire
        p.writeValue(wire, for: rx, type: .withResponse)
        // Typing time grows with length and the dongle's key delay.
        let t = DispatchWorkItem { [weak self] in
            self?.emit("no confirmation from the dongle")
            self?.finish(confirmed: false)
        }
        ackTimer = t
        q.asyncAfter(deadline: .now() + 5 + Double(wire.count) * 0.25, execute: t)
    }

    private func finish(confirmed: Bool) {
        ackTimer?.cancel(); ackTimer = nil
        guard let m = inFlight else { return }
        inFlight = nil
        if confirmed { onData?(Data(m.echo.utf8)) }
        work.leave()
        pump()
    }

    private func dropAll() {
        ackTimer?.cancel(); ackTimer = nil
        if inFlight != nil { inFlight = nil; work.leave() }
        pending.forEach { _ in work.leave() }
        pending.removeAll()
    }

    private func teardown() {
        scanTimer?.cancel(); scanTimer = nil
        dropAll()
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; rx = nil; linked = false
        central = nil
    }

    private func fail(_ reason: String) {
        guard isOpen else { return }
        emit(reason)                    // also visible to the API's /read
        setOpen(false)
        teardown()
        onClosed?(reason)
    }

    /// A dimmed status line in the terminal (and in the API's /read stream).
    private func emit(_ s: String) {
        onData?(Data("\r\n\u{1b}[2m[ \(s) ]\u{1b}[0m\r\n".utf8))
    }

    private func startScan() {
        guard isOpen, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        scanTimer?.cancel(); scanTimer = nil
        guard !everLinked else { return }      // after a drop, keep waiting for it to return
        let t = DispatchWorkItem { [weak self] in
            self?.fail("dongle not found — is it plugged in and powered?")
        }
        scanTimer = t
        q.asyncAfter(deadline: .now() + 20, execute: t)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    startScan()
        case .unauthorized: fail("Bluetooth permission denied — allow Serial Terminal under "
                                 + "System Settings ▸ Privacy & Security ▸ Bluetooth")
        case .poweredOff:   fail("Bluetooth is off")
        case .unsupported:  fail("Bluetooth is not available on this Mac")
        default:            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        if !params.name.isEmpty, name != params.name { return }
        scanTimer?.cancel(); scanTimer = nil
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        startScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let hadWork = inFlight != nil || !pending.isEmpty
        linked = false; rx = nil; self.peripheral = nil
        dropAll()
        guard isOpen else { return }
        emit(hadWork ? "dongle disconnected — unsent input dropped; waiting for it to come back…"
                     : "dongle disconnected — waiting for it to come back…")
        startScan()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail("device has no HID-bridge service"); return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let chars = service.characteristics ?? []
        rx = chars.first { $0.uuid == Self.rxUUID }
        guard rx != nil, let tx = chars.first(where: { $0.uuid == Self.txUUID }) else {
            fail("device is missing the HID-bridge characteristics"); return
        }
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        if let error { fail("could not subscribe to the dongle: \(error.localizedDescription)"); return }
        linked = true
        everLinked = true
        emit("linked to \(peripheral.name ?? "dongle") — what you type here is typed on the "
             + "device it is plugged into")
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.txUUID else { return }
        finish(confirmed: true)                 // the dongle's "ok": typing is done
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let error else { return }
        emit("write failed: \(error.localizedDescription)")
        finish(confirmed: false)
    }
}
