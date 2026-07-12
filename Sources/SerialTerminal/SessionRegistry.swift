import Foundation

/// Process-wide registry of open windows. Each window owns a `SerialSession` and
/// a `ControlServer` on its own port (8765, 8766, …). The registry hands out
/// ports and lets any server answer `GET /sessions` with the full list, so the
/// Claude skill can discover every window and target one by port.
final class SessionRegistry {
    static let shared = SessionRegistry()

    struct Info { let port: UInt16; let label: String; let connected: Bool }

    private let lock = NSLock()
    private let basePort: UInt16 = 8765
    private var used = Set<UInt16>()
    // port → snapshot closure (weak, so the registry never keeps a session alive)
    private var snapshots: [UInt16: () -> (label: String, connected: Bool)?] = [:]

    /// Reserve the lowest free port at/above the base.
    func allocatePort() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        var p = basePort
        while used.contains(p) { p += 1 }
        used.insert(p)
        return p
    }

    func register(port: UInt16, session: SerialSession) {
        lock.lock(); defer { lock.unlock() }
        snapshots[port] = { [weak session] in
            guard let s = session?.statusSnapshot() else { return nil }
            return (s.label, s.connected)
        }
    }

    func unregister(port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        snapshots[port] = nil
        used.remove(port)
    }

    /// All live windows, sorted by port.
    func list() -> [Info] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.keys.sorted().compactMap { port in
            guard let snap = snapshots[port]?() else { return nil }
            return Info(port: port, label: snap.label, connected: snap.connected)
        }
    }
}
