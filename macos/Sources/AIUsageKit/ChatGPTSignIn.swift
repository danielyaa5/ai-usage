import Foundation

/// Reading ChatGPT limits through Codex's app server when the saved sign-in has stopped working.
///
/// A plan change or a revoked session ends the saved ChatGPT token before the expiry date written
/// in it. Codex then answers `account/rateLimits/read` with a 401 ("token_expired") and does not
/// renew the token itself; `account/read` with `refreshToken` does. So the limits are read once,
/// and when the answer says the sign-in expired, the token is renewed and the limits read again.
public enum ChatGPTSignIn {
    public static let limitsMethod = "account/rateLimits/read"
    public static let renewMethod = "account/read"

    /// True when an error from Codex says the ChatGPT sign-in was rejected as expired or unauthorized.
    public static func isExpired(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["token_expired", "token has expired", "401 unauthorized", "invalid_token", "token_invalidated"]
            .contains { text.contains($0) }
    }

    /// Reads the limits, renewing the sign-in once when Codex reports it expired.
    /// `request` sends one JSON-RPC request; `describe` turns its error into text.
    public static func readLimits(request: (String, [String: Any]) async throws -> [String: Any],
                                  describe: (Error) -> String = { String(describing: $0) }) async throws -> [String: Any] {
        do {
            return try await request(limitsMethod, [:])
        } catch {
            guard isExpired(describe(error)) else { throw error }
            _ = try await request(renewMethod, ["refreshToken": true])
            return try await request(limitsMethod, [:])
        }
    }
}
