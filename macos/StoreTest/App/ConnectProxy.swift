import Foundation
import Network

/// A logging HTTP proxy for the bundled Codex, on 127.0.0.1. Codex is started with HTTPS_PROXY and
/// friends pointing here, so every host it asks to reach shows up: `CONNECT host:port` is noted and
/// the encrypted bytes are passed through unchanged (nothing is decrypted or kept). A plain-HTTP
/// request is noted (host and path, no query) and refused, and so is a CONNECT to any host but the
/// allowed ones, so nothing reaches another server even if one of Codex's settings stops working.
/// Each request is stamped with the test's stage as it arrives, before the proxy connects anywhere.
final class ConnectProxy: @unchecked Sendable {
    struct Contact: Sendable {
        var host: String
        var port: Int
        var method: String
        /// The test's stage when the request arrived.
        var stage: String
        var at: Date
        /// "tunneled", "closed", "refused …" or "could not connect …".
        var result: String
        var bytesUp: Int = 0
        var bytesDown: Int = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "AIUsageStoreTest.proxy")
    private let allowedHosts: Set<String>
    private let stage: @Sendable () -> String
    private let onContact: @Sendable (Contact) -> Void

    init(allowedHosts: Set<String>, stage: @escaping @Sendable () -> String,
         onContact: @escaping @Sendable (Contact) -> Void) throws {
        listener = try LoopbackListener.make(port: 0)
        self.allowedHosts = allowedHosts
        self.stage = stage
        self.onContact = onContact
    }

    func start(onFailure: @escaping @Sendable (String) -> Void) async -> UInt16? {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return await LoopbackListener.start(listener, queue: queue, onFailure: onFailure)
    }

    func stop() {
        listener.cancel()
    }

    private func note(_ host: String, _ port: Int, _ method: String, _ result: String, stage: String, up: Int = 0, down: Int = 0) {
        onContact(Contact(host: host, port: port, method: method, stage: stage, at: Date(), result: result,
                          bytesUp: up, bytesDown: down))
    }

    private func accept(_ client: NWConnection) {
        guard LoopbackListener.isLoopback(client.endpoint) else {
            client.cancel()
            return
        }
        client.start(queue: queue)
        readHead(client, buffer: Data())
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                client.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestHead.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    client.cancel()
                } else {
                    self.readHead(client, buffer: buffer)
                }
            case .invalid(let problem):
                self.note("?", 0, "?", "refused: \(problem)", stage: self.stage())
                self.refuse(client)
            case .complete(let head):
                let stage = self.stage()
                let early = buffer.subdata(in: (buffer.startIndex + head.length)..<buffer.endIndex)
                if head.method.uppercased() == "CONNECT" {
                    self.tunnel(client, target: head.target, early: early, stage: stage)
                } else {
                    let url = URL(string: head.target)
                    let host = url?.host ?? "?"
                    let path = url?.path ?? ""
                    self.note(host, url?.port ?? 80, "\(head.method) \(path)", "refused: plain HTTP", stage: stage)
                    self.refuse(client)
                }
            }
        }
    }

    private func refuse(_ client: NWConnection) {
        let reply = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        client.send(content: reply, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in client.cancel() })
    }

    private func tunnel(_ client: NWConnection, target: String, early: Data, stage: String) {
        guard let (host, port) = Self.split(target), let nwPort = NWEndpoint.Port(rawValue: port) else {
            note(target, 0, "CONNECT", "refused: bad target", stage: stage)
            refuse(client)
            return
        }
        guard port == 443, allowedHosts.contains(host.lowercased()) else {
            note(host, Int(port), "CONNECT", "refused: not an OpenAI sign-in or limits server", stage: stage)
            refuse(client)
            return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let pair = TunnelPair(client: client, upstream: upstream) { [weak self] up, down in
            self?.note(host, Int(port), "CONNECT", "closed", stage: stage, up: up, down: down)
        }
        let once = Once()
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard once.claim() else { return }
                self.note(host, Int(port), "CONNECT", "tunneled", stage: stage)
                let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: established, completion: .contentProcessed { error in
                    if error != nil {
                        pair.close()
                        return
                    }
                    if !early.isEmpty {
                        pair.countUp(early.count)
                        upstream.send(content: early, completion: .contentProcessed { _ in })
                    }
                    self.pump(from: client, to: upstream, pair: pair, upward: true)
                    self.pump(from: upstream, to: client, pair: pair, upward: false)
                })
            case .waiting(let error):
                guard once.claim() else { return }
                self.note(host, Int(port), "CONNECT", "could not connect: \(error)", stage: stage)
                upstream.cancel()
                self.refuse(client)
            case .failed(let error):
                if once.claim() {
                    self.note(host, Int(port), "CONNECT", "could not connect: \(error)", stage: stage)
                    upstream.cancel()
                    self.refuse(client)
                } else {
                    pair.close()
                }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection, pair: TunnelPair, upward: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                pair.close()
                return
            }
            if let data, !data.isEmpty {
                if upward { pair.countUp(data.count) } else { pair.countDown(data.count) }
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        pair.close()
                    } else if isComplete {
                        pair.endOneWay(destination)
                    } else if error != nil {
                        pair.close()
                    } else {
                        self.pump(from: source, to: destination, pair: pair, upward: upward)
                    }
                })
            } else if isComplete {
                pair.endOneWay(destination)
            } else if error != nil {
                pair.close()
            } else {
                self.pump(from: source, to: destination, pair: pair, upward: upward)
            }
        }
    }

    /// "host:port" or "[v6 address]:port".
    static func split(_ target: String) -> (String, UInt16)? {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]),
              colon > target.startIndex else { return nil }
        return (String(target[..<colon]), port)
    }
}

/// The two connections of one tunnel. Each direction ends on its own (passing the end of the stream
/// on), and both close when both directions have ended or either side fails.
final class TunnelPair: @unchecked Sendable {
    let client: NWConnection
    let upstream: NWConnection
    private let lock = NSLock()
    private var ended = 0
    private var closed = false
    private var up = 0
    private var down = 0
    private let onClose: @Sendable (Int, Int) -> Void

    init(client: NWConnection, upstream: NWConnection, onClose: @escaping @Sendable (Int, Int) -> Void) {
        self.client = client
        self.upstream = upstream
        self.onClose = onClose
    }

    func countUp(_ bytes: Int) {
        lock.lock()
        up += bytes
        lock.unlock()
    }

    func countDown(_ bytes: Int) {
        lock.lock()
        down += bytes
        lock.unlock()
    }

    func endOneWay(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        lock.lock()
        ended += 1
        let both = ended >= 2
        lock.unlock()
        if both { close() }
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let totals = (up, down)
        lock.unlock()
        client.cancel()
        upstream.cancel()
        onClose(totals.0, totals.1)
    }
}
