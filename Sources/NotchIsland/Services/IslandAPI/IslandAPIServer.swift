import Foundation
import Network

/// A tiny HTTP/1.1 server bound to 127.0.0.1 only. Just enough HTTP for small
/// `curl` requests: one request per connection, bodies up to 64 KB.
final class IslandAPIServer {
    struct Request {
        let method: String
        let path: String
        let query: String
        /// Header names are lower-cased.
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        let status: Int
        let json: [String: Any]

        static func ok(_ extra: [String: Any] = [:]) -> Response {
            Response(status: 200, json: ["ok": true].merging(extra) { $1 })
        }

        static func error(_ status: Int, _ message: String) -> Response {
            Response(status: status, json: ["ok": false, "error": message])
        }
    }

    static let port: UInt16 = 47290
    private static let maxRequestSize = 64 * 1024

    /// Called on the main thread for every complete request.
    private let handler: (Request) -> Response
    /// (listening, error message)
    var onStateChange: ((Bool, String?) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "NotchIsland.API.server")

    init(handler: @escaping (Request) -> Response) {
        self.handler = handler
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                let report: (Bool, String?)
                switch state {
                case .ready: report = (true, nil)
                case .failed(let error): report = (false, "Couldn't listen on port \(Self.port): \(error.localizedDescription)")
                case .cancelled: report = (false, nil)
                default: return
                }
                DispatchQueue.main.async { self?.onStateChange?(report.0, report.1) }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStateChange?(false, "Couldn't start the Island API: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop idle connections after a few seconds.
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxRequestSize {
                self.send(.error(413, "request too large"), on: connection)
            } else if let request = Self.parse(buffer) {
                DispatchQueue.main.async {
                    let response = self.handler(request)
                    self.queue.async { self.send(response, on: connection) }
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: response.json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count + 1)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        payload.append(Data("\n".utf8))
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        return Request(
            method: String(requestLine[0]).uppercased(),
            path: parts.first ?? "/",
            query: parts.count > 1 ? parts[1] : "",
            headers: headers,
            body: Data(body)
        )
    }

    /// Form-encoded or JSON body (plus query string) → flat string dictionary.
    static func parameters(of request: Request) -> [String: String] {
        var result = decodeForm(request.query)
        let bodyText = String(data: request.body, encoding: .utf8) ?? ""
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            for (key, value) in object {
                result[key] = (value as? String) ?? "\(value)"
            }
        } else {
            result.merge(decodeForm(trimmed)) { $1 }
        }
        return result
    }

    private static func decodeForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let rawKey = parts.first else { continue }
            func decode(_ s: String) -> String {
                s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
            }
            result[decode(rawKey)] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }
}
