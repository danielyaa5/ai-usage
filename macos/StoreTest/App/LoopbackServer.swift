import Foundation
import Network

/// TCP listeners that accept connections on 127.0.0.1 only. Binding the loopback address (rather than
/// every address) is what keeps macOS from asking whether the app may accept incoming connections.
enum LoopbackListener {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static func make(port: UInt16) throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure(description: "bad port \(port)") }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        return try NWListener(using: parameters)
    }

    /// Starts `listener` and waits until it is listening (its port) or has failed (nil).
    static func start(_ listener: NWListener, queue: DispatchQueue, timeout: TimeInterval = 5,
                      onFailure: @escaping @Sendable (String) -> Void) async -> UInt16? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                case .failed(let error):
                    onFailure("\(error)")
                    if once.claim() { continuation.resume(returning: nil) }
                case .waiting(let error):
                    onFailure("waiting: \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    onFailure("not listening after \(Int(timeout)) s")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// True when a connection comes from this Mac's loopback address.
    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        default: return false
        }
    }
}

/// The test's HTTP listener on 127.0.0.1. It answers `/ping` for the address checks and passes every
/// other request to the app (the status line snippet, the widget's results and the runner script).
final class LoopbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestHead, Data) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "AIUsageStoreTest.listener")
    private let handler: Handler
    private let maxBody = 1_000_000

    init(port: UInt16, handler: @escaping Handler) throws {
        listener = try LoopbackListener.make(port: port)
        self.handler = handler
    }

    /// Returns the port once listening, or nil (with the reason passed to `onFailure`).
    func start(onFailure: @escaping @Sendable (String) -> Void) async -> UInt16? {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return await LoopbackListener.start(listener, queue: queue, onFailure: onFailure)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard LoopbackListener.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        read(connection, buffer: Data(), sentContinue: false)
    }

    private func read(_ connection: NWConnection, buffer: Data, sentContinue: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestHead.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer, sentContinue: sentContinue)
                }
            case .invalid(let problem):
                self.send(.text(problem, status: 400), on: connection)
            case .complete(let head):
                if head.headers["transfer-encoding"] != nil {
                    self.send(.text("Send a Content-Length, not chunked encoding.", status: 411), on: connection)
                    return
                }
                guard let length = head.contentLength, length >= 0 else {
                    self.send(.text("Bad Content-Length.", status: 400), on: connection)
                    return
                }
                guard length <= self.maxBody else {
                    self.send(.text("Too large.", status: 413), on: connection)
                    return
                }
                if buffer.count - head.length < length {
                    if isComplete || error != nil {
                        connection.cancel()
                        return
                    }
                    var sent = sentContinue
                    if !sent, head.headers["expect"]?.lowercased() == "100-continue" {
                        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                                        completion: .contentProcessed { _ in })
                        sent = true
                    }
                    self.read(connection, buffer: buffer, sentContinue: sent)
                    return
                }
                let start = buffer.startIndex + head.length
                let body = buffer.subdata(in: start..<(start + length))
                let handler = self.handler
                Task {
                    let response = await handler(head, body)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
