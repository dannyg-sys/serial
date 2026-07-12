import Foundation
import Network

/// Minimal loopback HTTP/1.1 server exposing the serial session to external
/// tools (the Claude Code skill). Bound to 127.0.0.1 only.
final class ControlServer {
    private let session: SerialSession
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "control.server")
    private(set) var port: UInt16

    init(session: SerialSession, port: UInt16 = 8765) {
        self.session = session
        self.port = port
    }

    func start() {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Restrict to loopback so nothing off-box can reach the port.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)

        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("ControlServer failed: \(err)")
                }
            }
            l.start(queue: queue)
            listener = l
            DispatchQueue.main.async { self.session.httpPort = self.port }
        } catch {
            NSLog("ControlServer could not start on \(port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }

            if let req = HTTPRequest(parsing: buf) {
                self.handle(req, on: conn)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) {
        let (status, contentType, body) = route(req)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Routing

    private func route(_ req: HTTPRequest) -> (String, String, Data) {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/help"):
            return ok(text: helpText, type: "text/plain; charset=utf-8")

        case ("GET", "/ports"):
            return json(["ports": SerialPort.availablePorts()])

        case ("GET", "/status"):
            return json(statusDict())

        case ("GET", "/read"):
            let offset = Int(req.query["offset"] ?? "") ?? 0
            let r = session.read(fromOffset: offset)
            return json([
                "requestedOffset": offset,
                "base": r.base,
                "offset": r.next - r.data.count,
                "nextOffset": r.next,
                "bytes": r.data.count,
                "text": String(decoding: r.data, as: UTF8.self),
                "base64": r.data.base64EncodedString(),
            ])

        case ("POST", "/write"):
            return doWrite(req)

        case ("POST", "/connect"):
            return doConnect(req)

        case ("POST", "/disconnect"):
            session.disconnect()
            return json(["ok": true, "connected": false])

        default:
            return (
                "404 Not Found", "application/json",
                Data(#"{"error":"unknown endpoint"}"#.utf8)
            )
        }
    }

    private func doWrite(_ req: HTTPRequest) -> (String, String, Data) {
        var payload = Data()
        if req.headers["content-type"]?.contains("application/json") == true,
           let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
            if let b64 = obj["base64"] as? String, let d = Data(base64Encoded: b64) {
                payload = d
            } else if let text = obj["text"] as? String {
                payload = Data(text.utf8)
                switch (obj["newline"] as? String)?.lowercased() {
                case "cr": payload.append(0x0D)
                case "lf": payload.append(0x0A)
                case "crlf": payload.append(contentsOf: [0x0D, 0x0A])
                default: break
                }
            }
        } else {
            payload = req.body      // raw body = raw bytes
        }

        guard session.isConnected else {
            return ("409 Conflict", "application/json",
                    Data(#"{"error":"not connected"}"#.utf8))
        }
        do {
            let n = try session.send(payload)
            return json(["ok": true, "written": n])
        } catch {
            return ("500 Internal Server Error", "application/json",
                    Data("{\"error\":\(jsonString("\(error)"))}".utf8))
        }
    }

    private func doConnect(_ req: HTTPRequest) -> (String, String, Data) {
        let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        var s = session.settings
        if let p = obj["port"] as? String { session.selectedPort = p }
        let path = (obj["port"] as? String) ?? session.selectedPort
        if let b = obj["baud"] as? Int { s.baud = b }
        else if let b = obj["baud"] as? String, let bi = Int(b) { s.baud = bi }
        if let d = obj["dataBits"] as? Int { s.dataBits = d }
        if let st = obj["stopBits"] as? Int { s.stopBits = st }
        if let par = obj["parity"] as? String, let pv = Parity(rawValue: par.lowercased()) { s.parity = pv }

        guard !path.isEmpty else {
            return ("400 Bad Request", "application/json",
                    Data(#"{"error":"no port specified"}"#.utf8))
        }
        do {
            try session.connect(port: path, settings: s)
            return json(["ok": true, "connected": true, "port": path, "baud": s.baud])
        } catch {
            return ("500 Internal Server Error", "application/json",
                    Data("{\"error\":\(jsonString("\(error)"))}".utf8))
        }
    }

    private func statusDict() -> [String: Any] {
        [
            "connected": session.isConnected,
            "port": session.connectedPort ?? NSNull(),
            "baud": session.settings.baud,
            "dataBits": session.settings.dataBits,
            "parity": session.settings.parity.rawValue,
            "stopBits": session.settings.stopBits,
            "rxBytes": session.rxBytes,
            "txBytes": session.txBytes,
            "totalReceived": session.totalReceived(),
            "httpPort": Int(session.httpPort),
        ]
    }

    // MARK: - Response helpers

    private func ok(text: String, type: String) -> (String, String, Data) {
        ("200 OK", type, Data(text.utf8))
    }

    private func json(_ obj: [String: Any]) -> (String, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return ("200 OK", "application/json", data)
    }

    private func jsonString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        var str = String(decoding: d, as: UTF8.self)
        str.removeFirst(); str.removeLast()   // strip the array brackets
        return str
    }

    private var helpText: String {
        """
        Serial Terminal control API (loopback only)

          GET  /ports            list /dev/cu.* devices
          GET  /status           connection + settings + byte counters
          GET  /read?offset=N    received bytes since byte offset N
          POST /write            body: raw bytes, or JSON {text,newline,base64}
          POST /connect          JSON {port,baud,dataBits,parity,stopBits}
          POST /disconnect       close the port

        Use the `serial` skill helper instead of raw curl when possible.
        """
    }
}

// MARK: - Tiny HTTP request parser

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Parse a complete request from `buf`, or return nil if more bytes needed.
    init?(parsing buf: Data) {
        // Find header/body separator.
        guard let sep = HTTPRequest.range(of: [0x0D, 0x0A, 0x0D, 0x0A], in: buf) else { return nil }
        let headerData = buf.subdata(in: buf.startIndex..<sep.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])

        let rawTarget = String(parts[1])
        if let qm = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qm])
            var q: [String: String] = [:]
            for pair in rawTarget[rawTarget.index(after: qm)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0])
                let v = kv.count > 1 ? String(kv[1]) : ""
                q[k] = v.removingPercentEncoding ?? v
            }
            query = q
        } else {
            path = rawTarget
            query = [:]
        }

        lines.removeFirst()
        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            h[name] = value
        }
        headers = h

        let bodyStart = sep.upperBound
        let available = buf.subdata(in: bodyStart..<buf.endIndex)
        if let lenStr = h["content-length"], let len = Int(lenStr) {
            if available.count < len { return nil }   // wait for the rest of the body
            body = available.subdata(in: available.startIndex..<available.index(available.startIndex, offsetBy: len))
        } else {
            body = Data()
        }
    }

    private static func range(of pattern: [UInt8], in data: Data) -> Range<Data.Index>? {
        guard data.count >= pattern.count else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        while i <= bytes.count - pattern.count {
            if Array(bytes[i..<i+pattern.count]) == pattern {
                let lower = data.index(data.startIndex, offsetBy: i)
                let upper = data.index(lower, offsetBy: pattern.count)
                return lower..<upper
            }
            i += 1
        }
        return nil
    }
}
