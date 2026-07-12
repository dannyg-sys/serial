import Foundation

// Basic serial port parameters.
enum Parity: String, CaseIterable, Codable, Sendable {
    case none, even, odd
}

struct SerialSettings: Codable, Equatable, Sendable {
    var baud: Int = 9600
    var dataBits: Int = 8          // 5...8
    var parity: Parity = .none
    var stopBits: Int = 1          // 1 or 2
}

enum SerialError: Error, CustomStringConvertible {
    case openFailed(String, Int32)
    case configFailed(String, Int32)
    case notOpen
    case writeFailed(Int32)

    var description: String {
        switch self {
        case .openFailed(let path, let e):
            return "Cannot open \(path): \(String(cString: strerror(e))) (errno \(e))"
        case .configFailed(let what, let e):
            return "Configure failed (\(what)): \(String(cString: strerror(e))) (errno \(e))"
        case .notOpen:
            return "Port is not open"
        case .writeFailed(let e):
            return "Write failed: \(String(cString: strerror(e))) (errno \(e))"
        }
    }
}

// ioctl request for setting an arbitrary (non-standard) baud rate on macOS.
// _IOW('T', 2, speed_t): IOC_IN | (sizeof(speed_t)<<16) | ('T'<<8) | 2
private let IOSSIOSPEED: UInt = 0x8008_5402

/// Owns a POSIX serial file descriptor: open/configure via termios, async read
/// via a DispatchSource, and write. All callbacks fire on `queue`.
final class SerialPort {
    private(set) var fd: Int32 = -1
    private(set) var path: String = ""
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "serial.io")

    /// Called with newly received bytes (on the io queue).
    var onData: ((Data) -> Void)?
    /// Called when the port drops unexpectedly (device unplugged, etc.).
    var onClosed: ((String?) -> Void)?

    var isOpen: Bool { fd >= 0 }

    /// Enumerate candidate serial devices (`/dev/cu.*`).
    static func availablePorts() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    func open(path: String, settings: SerialSettings) throws {
        close()
        let fdLocal = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fdLocal >= 0 else { throw SerialError.openFailed(path, errno) }

        do {
            try Self.configure(fd: fdLocal, settings: settings)
        } catch {
            Darwin.close(fdLocal)
            throw error
        }

        self.fd = fdLocal
        self.path = path
        startReading()
    }

    /// Apply termios settings to an already-open fd (also used to reconfigure).
    static func configure(fd: Int32, settings: SerialSettings) throws {
        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else { throw SerialError.configFailed("tcgetattr", errno) }

        cfmakeraw(&tty)

        // Control flags: enable receiver, ignore modem control lines.
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)

        // Data bits.
        tty.c_cflag &= ~tcflag_t(CSIZE)
        switch settings.dataBits {
        case 5: tty.c_cflag |= tcflag_t(CS5)
        case 6: tty.c_cflag |= tcflag_t(CS6)
        case 7: tty.c_cflag |= tcflag_t(CS7)
        default: tty.c_cflag |= tcflag_t(CS8)
        }

        // Parity.
        switch settings.parity {
        case .none:
            tty.c_cflag &= ~tcflag_t(PARENB)
        case .even:
            tty.c_cflag |= tcflag_t(PARENB)
            tty.c_cflag &= ~tcflag_t(PARODD)
        case .odd:
            tty.c_cflag |= tcflag_t(PARENB | PARODD)
        }

        // Stop bits.
        if settings.stopBits >= 2 {
            tty.c_cflag |= tcflag_t(CSTOPB)
        } else {
            tty.c_cflag &= ~tcflag_t(CSTOPB)
        }

        // No hardware or software flow control.
        tty.c_cflag &= ~tcflag_t(CRTSCTS)
        tty.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)

        // Non-blocking read semantics (we drive reads from a DispatchSource).
        tty.c_cc.16 = 0   // VMIN
        tty.c_cc.17 = 0   // VTIME

        // Baud rate. macOS `tcsetattr` rejects non-standard rates (e.g. 1500000)
        // with EINVAL, so we always set a safe standard placeholder here and then
        // apply the *real* requested rate — standard or custom — via IOSSIOSPEED
        // after tcsetattr. This is Apple's documented path for arbitrary speeds.
        _ = cfsetispeed(&tty, speed_t(B9600))
        _ = cfsetospeed(&tty, speed_t(B9600))

        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            throw SerialError.configFailed("tcsetattr", errno)
        }

        var reqSpeed = speed_t(settings.baud)
        if ioctl(fd, IOSSIOSPEED, &reqSpeed) == -1 {
            let e = errno
            throw SerialError.configFailed("set baud \(settings.baud) (device may not support this rate)", e)
        }
    }

    /// Reconfigure the live connection without closing it.
    func reconfigure(settings: SerialSettings) throws {
        guard isOpen else { throw SerialError.notOpen }
        try Self.configure(fd: fd, settings: settings)
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self = self, self.fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(self.fd, &buf, buf.count)
            if n > 0 {
                self.onData?(Data(buf[0..<n]))
            } else if n == 0 {
                self.handleUnexpectedClose(reason: "EOF")
            } else {
                let e = errno
                if e != EAGAIN && e != EWOULDBLOCK {
                    self.handleUnexpectedClose(reason: String(cString: strerror(e)))
                }
            }
        }
        source = src
        src.resume()
    }

    private func handleUnexpectedClose(reason: String?) {
        let cb = onClosed
        close()
        cb?(reason)
    }

    @discardableResult
    func write(_ data: Data) throws -> Int {
        guard isOpen else { throw SerialError.notOpen }
        var total = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while total < data.count {
                let n = Darwin.write(fd, base + total, data.count - total)
                if n > 0 {
                    total += n
                } else {
                    let e = errno
                    if e == EAGAIN || e == EWOULDBLOCK {
                        usleep(1000)
                        continue
                    }
                    throw SerialError.writeFailed(e)
                }
            }
        }
        return total
    }

    func close() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        path = ""
    }

    deinit { close() }
}
