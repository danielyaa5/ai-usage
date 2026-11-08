import Network
import Foundation

enum PortProbe {
    /// Opens a TCP connection with Network.framework and reports the first settled state, including
    /// the reason macOS gives when the path is unsatisfied (for example `localNetworkDenied`).
    static func run(host: String, port: UInt16, timeout: TimeInterval = 6) async -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return "bad port \(port)" }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "AIUsageStoreTest.probe")
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = Once()
            let finish: @Sendable (String) -> Void = { result in
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish("ready")
                case .waiting(let error):
                    finish("waiting: \(error); path: \(pathText(connection.currentPath))")
                case .failed(let error):
                    finish("failed: \(error); path: \(pathText(connection.currentPath))")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish("no answer in \(Int(timeout)) s; path: \(pathText(connection.currentPath))")
            }
        }
    }

    private static func pathText(_ path: NWPath?) -> String {
        guard let path else { return "none" }
        var text = "\(path.status)"
        if path.status != .satisfied {
            text += " (\(path.unsatisfiedReason))"
        }
        return text
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
