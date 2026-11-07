import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var contentType: String = "application/json"
    var body: Data = Data()

    static func json(_ o: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: jsonData(o))
    }
    static func empty(_ status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, contentType: "text/plain") }
}

/// Tiny HTTP/1.1 server bound to 127.0.0.1. One request per connection.
final class HTTPServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentboard.http", attributes: .concurrent)
    var onState: ((Bool, String?) -> Void)?

    init(port: Int, handler: @escaping Handler) {
        self.port = UInt16(port)
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(true, nil)
            case .failed(let e): self?.onState?(false, "Порт \(self?.port ?? 0): \(e.localizedDescription)")
            case .cancelled: self?.onState?(false, nil)
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                var answered = false
                let lock = NSLock()
                self.handler(req) { resp in
                    lock.lock(); defer { lock.unlock() }
                    if answered { return }
                    answered = true
                    self.send(c, resp)
                }
                return
            }
            if isComplete || error != nil || buf.count > 32_000_000 {
                c.cancel()
                return
            }
            self.receive(c, buf)
        }
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"][r.status] ?? "OK"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    static func parse(_ buf: Data) -> HTTPRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buf.range(of: sep) else { return nil }
        let headerText = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = range.upperBound
        var body = Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(buf[bodyStart...]) else { return nil }
            body = decoded
        } else {
            let len = Int(headers["content-length"] ?? "0") ?? 0
            if buf.count - bodyStart < len { return nil }
            body = buf[bodyStart..<(bodyStart + len)]
        }
        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
        }
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query,
                           headers: headers, body: Data(body))
    }

    /// Returns nil until the final zero-size chunk has arrived.
    private static func decodeChunked(_ data: Data) -> Data? {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data[i...].range(of: crlf) else { return nil }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? "0"
            guard let size = Int(sizeText.trimmed, radix: 16) else { return nil }
            let start = lineEnd.upperBound
            if size == 0 { return out }
            guard data.endIndex >= start + size + 2 else { return nil }
            out.append(data[start..<(start + size)])
            i = start + size + 2
        }
    }
}
