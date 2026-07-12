import Foundation
import Darwin

/// Parses ~/.ssh/config (and its `Include`d files) to discover the `Host`
/// aliases the user can connect to. We only enumerate names — the actual
/// connection is made by the system `ssh`, which re-reads the same config and
/// applies HostName / User / IdentityFile / ProxyJump / agent on its own.
enum SSHConfig {
    struct HostEntry: Equatable {
        let alias: String
        var hostName: String?
        var user: String?

        /// "alias — user@hostname" style subtitle for the picker.
        var subtitle: String? {
            switch (user, hostName) {
            case let (u?, h?): return "\(u)@\(h)"
            case let (nil, h?): return h
            case let (u?, nil): return "\(u)@"
            default: return nil
            }
        }
    }

    static func discoverHosts() -> [HostEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var entries: [HostEntry] = []
        var index: [String: Int] = [:]
        var visited = Set<String>()
        parse(path: home + "/.ssh/config", home: home,
              entries: &entries, index: &index, visited: &visited, depth: 0)
        return entries.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private static func parse(path: String, home: String,
                              entries: inout [HostEntry], index: inout [String: Int],
                              visited: inout Set<String>, depth: Int) {
        guard depth < 16 else { return }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !visited.contains(canonical) else { return }
        visited.insert(canonical)
        guard let text = try? String(contentsOfFile: canonical, encoding: .utf8) else { return }

        var currentAliases: [String] = []   // Host block that following keys apply to

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // "Keyword value..." — keyword may be separated by spaces or '='.
            let normalized = line.replacingOccurrences(of: "=", with: " ")
            let tokens = normalized.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = tokens.first?.lowercased() else { continue }
            let values = Array(tokens.dropFirst())

            switch keyword {
            case "host":
                currentAliases = []
                for pat in values where !pat.contains("*") && !pat.contains("?") && !pat.hasPrefix("!") {
                    currentAliases.append(pat)
                    if index[pat] == nil {
                        index[pat] = entries.count
                        entries.append(HostEntry(alias: pat, hostName: nil, user: nil))
                    }
                }

            case "match":
                currentAliases = []   // Match blocks don't define connectable aliases

            case "hostname":
                if let v = values.first {
                    for a in currentAliases { if let i = index[a] { entries[i].hostName = v } }
                }

            case "user":
                if let v = values.first {
                    for a in currentAliases { if let i = index[a] { entries[i].user = v } }
                }

            case "include":
                currentAliases = []
                for token in values {
                    for file in expandInclude(token, home: home) {
                        parse(path: file, home: home,
                              entries: &entries, index: &index, visited: &visited, depth: depth + 1)
                    }
                }

            default:
                break
            }
        }
    }

    /// Expand an `Include` argument (globs allowed; relative paths resolve under ~/.ssh).
    private static func expandInclude(_ token: String, home: String) -> [String] {
        var pattern = token
        if !pattern.hasPrefix("/") && !pattern.hasPrefix("~") {
            pattern = home + "/.ssh/" + pattern
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, GLOB_TILDE | GLOB_BRACE, nil, &g) == 0 else { return [] }
        var out: [String] = []
        for i in 0..<Int(g.gl_pathc) {
            if let c = g.gl_pathv[i] { out.append(String(cString: c)) }
        }
        return out
    }
}
