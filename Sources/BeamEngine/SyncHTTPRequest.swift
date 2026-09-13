import Foundation

/// Minimal, bounded request parsing for the local browser bridge.
public struct SyncHTTPRequest: Equatable, Sendable {
    public let target: String
    public let route: String
    public let origin: String?
    public let authorizedControl: Bool

    public enum Failure: Error { case malformed, method, origin, host, route }

    public init(header: String) throws {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { throw Failure.malformed }
        guard request[0] == "GET" else { throw Failure.method }
        let target = String(request[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { throw Failure.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw Failure.malformed }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if let host = headers["host"], !["127.0.0.1:3697", "localhost:3697", "[::1]:3697"].contains(host.lowercased()) { throw Failure.host }
        let origin = headers["origin"]
        let extensionOrigin = origin.map { value in
            guard let url = URL(string: value), url.scheme == "chrome-extension", let host = url.host else { return false }
            return host.count == 32 && host.allSatisfy { ("a"..."p").contains(String($0)) } && (url.path.isEmpty || url.path == "/")
        } ?? false
        if origin != nil && !extensionOrigin { throw Failure.origin }
        let route = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        guard ["/", "/cut", "/resume", "/now"].contains(route) else { throw Failure.route }
        let authorized = extensionOrigin || headers["x-dali-client"] == "chrome-extension"
        guard route == "/" || authorized else { throw Failure.origin }
        self.target = target
        self.route = route
        self.origin = origin
        self.authorizedControl = authorized
    }
}
