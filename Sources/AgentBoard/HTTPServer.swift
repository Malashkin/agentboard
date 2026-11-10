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

    // Limits (audit L3): any local process can connect, so memory and sockets are bounded.
    /// Largest request (headers + body). Hook payloads with big tool output stay well under it.
    let maxRequestBytes: Int
    /// Hook requests waiting for a decision stay open (up to an hour), so this is generous.
    let maxConnections: Int
    /// A request must arrive completely within this time.
    let readTimeout: Double
    private let countLock = NSLock()
    private var openConnections = 0

    init(port: Int, maxRequestBytes: Int = 8 << 20, maxConnections: Int = 256, readTimeout: Double = 30,
         handler: @escaping Handler) {
        self.port = UInt16(port)
        self.maxRequestBytes = maxRequestBytes
        self.maxConnections = maxConnections
        self.readTimeout = readTimeout
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
            case .failed(let e): self?.onState?(false, "Port \(self?.port ?? 0): \(e.localizedDescription)")
            case .cancelled: self?.onState?(false, nil)
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() { listener?.cancel(); listener = nil }

    /// One per connection: makes sure the open-connection count is decremented exactly once.
    private final class ConnState {
        var closed = false
        var gotRequest = false
        let lock = NSLock()
    }

    private func accept(_ c: NWConnection) {
        countLock.lock()
        if openConnections >= maxConnections {
            countLock.unlock()
            c.cancel()
            return
        }
        openConnections += 1
        countLock.unlock()
        let st = ConnState()
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                st.lock.lock(); let first = !st.closed; st.closed = true; st.lock.unlock()
                if first, let self { self.countLock.lock(); self.openConnections -= 1; self.countLock.unlock() }
                if case .failed = state { c.cancel() }
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + readTimeout) {
            st.lock.lock(); let idle = !st.gotRequest && !st.closed; st.lock.unlock()
            if idle { c.cancel() }
        }
        receive(c, Data(), st)
    }

    var connectionCount: Int { countLock.lock(); defer { countLock.unlock() }; return openConnections }

    private func receive(_ c: NWConnection, _ buffer: Data, _ st: ConnState) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if Self.declaredTooLarge(buf, limit: self.maxRequestBytes) || buf.count > self.maxRequestBytes {
                st.lock.lock(); st.gotRequest = true; st.lock.unlock()
                self.send(c, .json(["error": "request too large"], status: 413))
                return
            }
            if let req = Self.parse(buf) {
                st.lock.lock(); st.gotRequest = true; st.lock.unlock()
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
            if isComplete || error != nil {
                c.cancel()
                return
            }
            self.receive(c, buf, st)
        }
    }

    /// Content-Length above the limit is refused as soon as the headers are in, before buffering the body.
    static func declaredTooLarge(_ buf: Data, limit: Int) -> Bool {
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buf[buf.startIndex..<range.lowerBound], as: UTF8.self).lowercased()
        for line in head.components(separatedBy: "\r\n") where line.hasPrefix("content-length:") {
            let v = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            if let n = Int(v), n > limit { return true }
            if Int(v) == nil { return true }   // overflow / garbage
        }
        return false
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        let reason = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 415: "Unsupported Media Type",
                      503: "Service Unavailable", 500: "Internal Server Error"][r.status] ?? "OK"
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
