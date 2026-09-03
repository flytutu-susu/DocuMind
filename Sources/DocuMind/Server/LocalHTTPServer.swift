import Foundation
import Network

// MARK: - 简化 HTTP 模型

struct HTTPRequest {
    let method: String
    let path: String                       // 不含 query
    let query: [String: String]
    let headers: [String: String]          // key 统一小写
    let body: Data
    let remoteAddress: String

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return HTTPResponse(statusCode: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
    }

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: ["Content-Type": contentType], body: Data(text.utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["error": message], status: status)
    }

    fileprivate var statusText: String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Status \(statusCode)"
        }
    }
}

// MARK: - 基于 Network.framework 的轻量 HTTP 服务

/// 零第三方依赖的局域网 HTTP 服务器。
/// 每个请求一个连接（Connection: close），满足内置 Web 页面的调用模式。
final class LocalHTTPServer: @unchecked Sendable {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private let port: UInt16
    private let handler: Handler
    private let maxBodyBytes: Int

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.documind.httpserver")
    private var connections: Set<NWConnection> = []
    private let lock = NSLock()

    private(set) var isRunning = false

    init(port: UInt16, maxBodyBytes: Int = 200 * 1024 * 1024, handler: @escaping Handler) {
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
    }

    // MARK: - 生命周期

    func start() throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "DocuMind", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效端口 \(port)"])
        }
        // 默认参数即监听所有网卡（IPv4/IPv6 双栈），局域网可访问
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                NSLog("[DocuMind] HTTP 服务已启动，端口 \(self.port)")
            case .failed(let error):
                self.isRunning = false
                NSLog("[DocuMind] HTTP 服务失败: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        lock.lock()
        let conns = connections
        connections.removeAll()
        lock.unlock()
        conns.forEach { $0.cancel() }
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.insert(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.remove(connection)
            } else if case .failed = state {
                self?.remove(connection)
            }
        }
        connection.start(queue: queue)

        Task { [weak self] in
            await self?.handle(connection)
        }
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.remove(connection)
        lock.unlock()
    }

    private func handle(_ connection: NWConnection) async {
        do {
            guard let request = try await readRequest(connection) else {
                connection.cancel()
                return
            }
            let response = await handler(request)
            try await send(response, on: connection)
        } catch {
            NSLog("[DocuMind] 请求处理失败: \(error.localizedDescription)")
            let resp = HTTPResponse.error(500, error.localizedDescription)
            try? await send(resp, on: connection)
        }
        connection.cancel()
        remove(connection)
    }

    // MARK: - 请求读取

    private func readRequest(_ connection: NWConnection) async throws -> HTTPRequest? {
        var buffer = Data()

        // 1) 读到头部结束
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try await receiveChunk(connection)
            if chunk.isEmpty { return nil }  // EOF
            buffer.append(chunk)
            if buffer.count > 64 * 1024 { throw HTTPError.headersTooLarge }
        }

        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        var body = buffer.subdata(in: headerEnd.upperBound..<buffer.count)

        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let (path, query) = Self.splitPathAndQuery(rawTarget)

        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if contentLength > maxBodyBytes { throw HTTPError.bodyTooLarge }

        // 2) 读满 body
        while body.count < contentLength {
            let chunk = try await receiveChunk(connection)
            if chunk.isEmpty { break }
            body.append(chunk)
        }
        if body.count > contentLength {
            body = body.subdata(in: 0..<contentLength)
        }

        let remote = connection.endpoint.debugDescription
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body, remoteAddress: remote)
    }

    private func receiveChunk(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - 响应发送

    private func send(_ response: HTTPResponse, on connection: NWConnection) async throws {
        var head = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    // MARK: - 工具

    private static func splitPathAndQuery(_ target: String) -> (String, [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (target.removingPercentEncoding ?? target, [:])
        }
        let path = String(target[..<qIndex])
        let queryString = String(target[target.index(after: qIndex)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            query[key] = value
        }
        return (path.removingPercentEncoding ?? path, query)
    }

    enum HTTPError: LocalizedError {
        case headersTooLarge
        case bodyTooLarge

        var errorDescription: String? {
            switch self {
            case .headersTooLarge: return "请求头过大"
            case .bodyTooLarge: return "请求体超过大小限制"
            }
        }
    }

    // MARK: - 局域网地址

    /// 枚举本机局域网 IPv4 地址（排除回环）。
    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let ifaAddr = interface.ifa_addr else { continue }
            let family = ifaAddr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }   // en0/en1 等物理网卡
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addrLen = socklen_t(ifaAddr.pointee.sa_len)
            if getnameinfo(ifaAddr, addrLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if !ip.hasPrefix("127.") { addresses.append(ip) }
            }
        }
        return addresses
    }
}
