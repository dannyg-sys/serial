import Foundation
import CoreBluetooth

/// An HID-bridge dongle seen while scanning.
struct HIDDongle: Identifiable, Equatable {
    let id: UUID            // CoreBluetooth identifier (stable on this Mac)
    var name: String        // advertised name, e.g. "T-Dongle HID F0A8"
    var rssi: Int
}

/// Scans for HID-bridge dongles so the picker and the API can list them. A dongle
/// that is already linked (by any window) does not advertise and is not listed.
final class HIDDongleScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var dongles: [HIDDongle] = []
    @Published private(set) var problem: String = ""     // Bluetooth off / not allowed

    private let q = DispatchQueue(label: "hid.scan")
    private var central: CBCentralManager?               // on q
    private var found: [UUID: HIDDongle] = [:]           // on q

    func start() {
        q.async { [weak self] in
            guard let self, self.central == nil else { return }
            self.central = CBCentralManager(delegate: self, queue: self.q)
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self else { return }
            self.central?.stopScan()
            self.central = nil
            self.found.removeAll()
            self.publish()
        }
    }

    /// What has been seen so far (any thread).
    func snapshot() -> [HIDDongle] { q.sync { sorted() } }

    /// Blocking one-shot scan, for the control API.
    static func scanOnce(seconds: TimeInterval) -> [HIDDongle] {
        let s = HIDDongleScanner()
        s.start()
        Thread.sleep(forTimeInterval: seconds)
        let result = s.snapshot()
        s.stop()
        return result
    }

    private func sorted() -> [HIDDongle] { found.values.sorted { $0.name < $1.name } }

    private func publish() {
        let list = sorted()
        DispatchQueue.main.async { [weak self] in self?.dongles = list }
    }

    private func report(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.problem = s }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            report("")
            central.scanForPeripherals(withServices: [HIDBridgeTransport.serviceUUID],
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .unauthorized: report("Bluetooth is not allowed for Serial Terminal (System Settings ▸ Privacy & Security ▸ Bluetooth)")
        case .poweredOff:   report("Bluetooth is off")
        case .unsupported:  report("Bluetooth is not available on this Mac")
        default:            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Prefer the advertised name: the cached `peripheral.name` can be stale.
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? found[peripheral.identifier]?.name ?? peripheral.name ?? "T-Dongle"
        let entry = HIDDongle(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        let old = found[peripheral.identifier]
        found[peripheral.identifier] = entry
        if old?.name != entry.name { publish() }         // ignore pure signal-strength updates
    }
}
