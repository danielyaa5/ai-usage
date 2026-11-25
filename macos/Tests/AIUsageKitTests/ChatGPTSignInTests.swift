import XCTest
@testable import AIUsageKit

final class ChatGPTSignInTests: XCTestCase {
    struct RPCError: Error, CustomStringConvertible { let description: String }

    /// What Codex 0.166.0 returned for a sign-in made before a ChatGPT plan change.
    static let expired = RPCError(description: #"account/rateLimits/read: error -32603: failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; content-type=text/plain; body={"error":{"message":"Your authentication token has expired. Please try refreshing it.","type":"invalid_request_error","code":"token_expired","param":null},"status":401}"#)

    final class FakeServer: @unchecked Sendable {
        var calls: [(String, [String: Any])] = []
        var answers: [Result<[String: Any], Error>]
        init(_ answers: [Result<[String: Any], Error>]) { self.answers = answers }
        func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            calls.append((method, params))
            return try answers.removeFirst().get()
        }
        var methods: [String] { calls.map(\.0) }
    }

    func testValidSignInReadsLimitsOnce() async throws {
        let server = FakeServer([.success(["rateLimits": ["planType": "prolite"]])])
        let reply = try await ChatGPTSignIn.readLimits(request: server.request)
        XCTAssertEqual(server.methods, ["account/rateLimits/read"])
        XCTAssertNotNil(reply["rateLimits"])
    }

    func testExpiredSignInIsRenewedThenLimitsReadAgain() async throws {
        let server = FakeServer([.failure(Self.expired), .success(["account": ["planType": "prolite"]]),
                                 .success(["rateLimits": ["planType": "prolite"]])])
        let reply = try await ChatGPTSignIn.readLimits(request: server.request)
        XCTAssertEqual(server.methods, ["account/rateLimits/read", "account/read", "account/rateLimits/read"])
        XCTAssertEqual(server.calls[1].1["refreshToken"] as? Bool, true)
        XCTAssertNotNil(reply["rateLimits"])
    }

    func testOtherFailuresAreNotRetried() async {
        let server = FakeServer([.failure(RPCError(description: "account/rateLimits/read: no answer in time"))])
        do {
            _ = try await ChatGPTSignIn.readLimits(request: server.request)
            XCTFail("expected the timeout to be thrown")
        } catch {
            XCTAssertEqual(server.methods, ["account/rateLimits/read"])
        }
    }

    func testRenewalIsTriedOnlyOnce() async {
        let server = FakeServer([.failure(Self.expired), .success([:]), .failure(Self.expired)])
        do {
            _ = try await ChatGPTSignIn.readLimits(request: server.request)
            XCTFail("expected the second expired answer to be thrown")
        } catch {
            XCTAssertEqual(server.methods, ["account/rateLimits/read", "account/read", "account/rateLimits/read"])
        }
    }

    func testFailedRenewalIsThrown() async {
        let server = FakeServer([.failure(Self.expired), .failure(RPCError(description: "account/read: error -32603: refresh token was revoked"))])
        do {
            _ = try await ChatGPTSignIn.readLimits(request: server.request)
            XCTFail("expected the renewal failure to be thrown")
        } catch {
            XCTAssertEqual(server.methods, ["account/rateLimits/read", "account/read"])
        }
    }

    func testExpiredWording() {
        XCTAssertTrue(ChatGPTSignIn.isExpired(Self.expired.description))
        XCTAssertTrue(ChatGPTSignIn.isExpired("GET /wham/usage failed: 401 Unauthorized"))
        XCTAssertFalse(ChatGPTSignIn.isExpired("account/rateLimits/read: no answer in time"))
        XCTAssertFalse(ChatGPTSignIn.isExpired("GET /wham/usage failed: 503 Service Unavailable"))
    }
}
