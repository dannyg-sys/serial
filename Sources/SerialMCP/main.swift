import Foundation

// MCP (Model Context Protocol) shim for Serial Terminal.
//
// Speaks JSON-RPC on stdin/stdout (one JSON message per line) and forwards every
// tool call to the running app's loopback HTTP API. It owns no connection
// itself: the app keeps the one serial / SSH / Bluetooth link, and Claude
// Desktop, the GUI and the `serial` skill helper all share it.

let defaultPort = Int(ProcessInfo.processInfo.environment["SERIAL_API_PORT"] ?? "") ?? 8765
var readOffsets: [Int: Int] = [:]           // per window: where the last `read` stopped

struct ToolError: Error { let message: String }

final class Box<T> { var value: T; init(_ v: T) { value = v } }

/// One call to the app's control API. Throws with a readable message.
func api(_ method: String, _ path: String, port: Int, body: [String: Any]? = nil,
         timeout: TimeInterval = 20) throws -> [String: Any] {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
        throw ToolError(message: "bad request path")
    }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = method
    if let body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    let result = Box<Result<[String: Any], ToolError>>(.failure(ToolError(message: "no response")))
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        if err != nil {
            result.value = .failure(ToolError(message:
                "Serial Terminal is not reachable on port \(port) — open the app first"))
            return
        }
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        if let e = obj["error"] as? String { result.value = .failure(ToolError(message: e)); return }
        result.value = .success(obj)
    }.resume()
    sem.wait()
    return try result.value.get()
}

func pretty(_ obj: Any) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
    return d.flatMap { String(data: $0, encoding: .utf8) } ?? "\(obj)"
}

// MARK: - Tool catalogue

func tool(_ name: String, _ description: String, _ props: [String: Any] = [:],
          required: [String] = []) -> [String: Any] {
    var p = props
    p["port"] = ["type": "integer",
                 "description": "API port of the app window to use (default \(defaultPort); see `sessions`)"]
    return ["name": name, "description": description,
            "inputSchema": ["type": "object", "properties": p, "required": required]]
}

let str: [String: Any] = ["type": "string"]
let tools: [[String: Any]] = [
    tool("sessions", "List the open Serial Terminal windows: each is one connection with its own API port."),
    tool("status", "Connection state of a window: kind (serial / ssh / hid), label, linked (hid), byte counters."),
    tool("list_dongles", "List the HID keyboard-bridge dongles in Bluetooth range. Each name ends in a 4-character id that is also shown on the dongle's display. A dongle already linked by a window is not listed."),
    tool("connect_hid",
         "Connect a window to a Bluetooth HID keyboard-bridge dongle. Text sent afterwards is typed as a USB keyboard on whatever device that dongle is plugged into (TV, headless box, login prompt). If several dongles are in range a name is required: ask the user which one (the id is on its display) rather than guessing.",
         ["name": ["type": "string", "description": "The dongle's name or just its 4-character id, e.g. F0A8"]]),
    tool("connect_serial", "Open a local serial port in a window.",
         ["device": ["type": "string", "description": "e.g. /dev/cu.usbserial-1420"],
          "baud": ["type": "integer", "description": "default 9600"]],
         required: ["device"]),
    tool("connect_ssh", "Connect a window over SSH (uses ~/.ssh/config). With `device`, bridge that remote serial device instead of a login shell.",
         ["host": str, "device": ["type": "string", "description": "e.g. /dev/ttyUSB0 (optional)"],
          "baud": ["type": "integer"]],
         required: ["host"]),
    tool("disconnect", "Close the window's connection."),
    tool("read", "Return what the connection received since the previous read (serial / ssh output; for hid, the echo of what was typed plus link messages).",
         ["all": ["type": "boolean", "description": "Return the whole retained buffer instead"]]),
    tool("write", "Send text to the connection. On an hid window it is typed on the target device at about 30 characters a second and the call returns once it has been typed.",
         ["text": str,
          "newline": ["type": "string", "enum": ["none", "cr", "lf", "crlf"],
                      "description": "Line ending to append (default none). On hid, cr or lf presses Enter."]],
         required: ["text"]),
    tool("press_key", "hid only: press one key — enter, tab, esc, space, backspace, delete, up, down, left, right, home, end.",
         ["key": str], required: ["key"]),
    tool("send_combo", "hid only: press a key combination, e.g. ctrl+c, ctrl+alt+t, alt+tab, gui+r.",
         ["combo": str], required: ["combo"]),
    tool("set_key_delay", "hid only: gap between keystrokes in ms (default 20, about 30 chars/s). Raise it if the target drops characters.",
         ["ms": ["type": "integer"]], required: ["ms"]),
]

// MARK: - Tool dispatch

func typedOrThrow(_ r: [String: Any]) throws {
    if (r["typed"] as? Bool) == false {
        throw ToolError(message: "the dongle did not confirm — the keys may not have been typed")
    }
}

func call(_ name: String, _ a: [String: Any]) throws -> String {
    let port = (a["port"] as? Int) ?? defaultPort
    switch name {
    case "sessions":
        for p in 8765...8775 {
            if let r = try? api("GET", "/sessions", port: p, timeout: 1) { return pretty(r["sessions"] ?? []) }
        }
        throw ToolError(message: "no Serial Terminal window found — open the app first")

    case "status":
        return pretty(try api("GET", "/status", port: port))

    case "list_dongles":
        return pretty(try api("GET", "/hiddevices", port: port)["dongles"] ?? [])

    case "connect_hid":
        var body: [String: Any] = ["type": "hid"]
        if let n = a["name"] as? String, !n.isEmpty { body["name"] = n }
        _ = try api("POST", "/connect", port: port, body: body)
        readOffsets[port] = 0
        for _ in 0..<25 {                       // the BLE link comes up in the background
            Thread.sleep(forTimeInterval: 1)
            let s = try api("GET", "/status", port: port)
            if (s["linked"] as? Bool) == true { return "linked to the dongle" }
            if (s["connected"] as? Bool) == false { break }
        }
        let log = (try? api("GET", "/read?offset=0", port: port))?["text"] as? String ?? ""
        throw ToolError(message: "could not link to the dongle. \(log)")

    case "connect_serial":
        var body: [String: Any] = ["port": a["device"] as? String ?? ""]
        if let b = a["baud"] as? Int { body["baud"] = b }
        readOffsets[port] = 0
        return pretty(try api("POST", "/connect", port: port, body: body))

    case "connect_ssh":
        var body: [String: Any] = ["type": "ssh", "host": a["host"] as? String ?? ""]
        if let d = a["device"] as? String, !d.isEmpty { body["device"] = d }
        if let b = a["baud"] as? Int { body["baud"] = b }
        readOffsets[port] = 0
        return pretty(try api("POST", "/connect", port: port, body: body))

    case "disconnect":
        return pretty(try api("POST", "/disconnect", port: port))

    case "read":
        let offset = (a["all"] as? Bool) == true ? 0 : (readOffsets[port] ?? 0)
        let r = try api("GET", "/read?offset=\(offset)", port: port)
        readOffsets[port] = (r["nextOffset"] as? Int) ?? offset
        return (r["text"] as? String) ?? ""

    case "write":
        let text = a["text"] as? String ?? ""
        var body: [String: Any] = ["text": text]
        if let nl = a["newline"] as? String, nl != "none" { body["newline"] = nl }
        // On hid the app answers only when the text has been typed (~30 chars/s).
        let r = try api("POST", "/write", port: port, body: body,
                        timeout: 60 + Double(text.utf8.count) * 0.3)
        try typedOrThrow(r)
        return r["typed"] != nil ? "typed \(text.utf8.count) characters" : pretty(r)

    case "press_key", "send_combo", "set_key_delay":
        let body: [String: Any]
        switch name {
        case "press_key":  body = ["key": a["key"] as? String ?? ""]
        case "send_combo": body = ["combo": a["combo"] as? String ?? ""]
        default:           body = ["delay": a["ms"] as? Int ?? 20]
        }
        try typedOrThrow(try api("POST", "/hid", port: port, body: body, timeout: 60))
        return "done"

    default:
        throw ToolError(message: "unknown tool \(name)")
    }
}

// MARK: - JSON-RPC loop

func reply(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return }
    print(s)
    fflush(stdout)
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    guard let id = msg["id"] else { continue }          // notifications need no answer
    let params = msg["params"] as? [String: Any] ?? [:]

    switch msg["method"] as? String ?? "" {
    case "initialize":
        reply(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "serial-terminal", "version": "1.0"],
        ] as [String: Any]])

    case "ping":
        reply(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])

    case "tools/list":
        reply(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])

    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        var text: String
        var isError = false
        do { text = try call(name, args) }
        catch let e as ToolError { text = e.message; isError = true }
        catch { text = "\(error)"; isError = true }
        reply(["jsonrpc": "2.0", "id": id, "result": [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ] as [String: Any]])

    default:
        reply(["jsonrpc": "2.0", "id": id,
               "error": ["code": -32601, "message": "method not found"] as [String: Any]])
    }
}
