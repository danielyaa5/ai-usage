import AppKit
import AuthenticationServices

/// Shows Codex's ChatGPT sign-in page in an ASWebAuthenticationSession. After the sign-in, OpenAI
/// sends the browser to Codex's own login server on 127.0.0.1, which never matches the callback
/// scheme, so the session doesn't end by itself: the app cancels it when Codex reports the sign-in
/// finished.
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// A scheme nothing navigates to. It has to be a valid one: Chrome on macOS 14.0 to 14.3 can't
    /// handle a session without one.
    static let callbackScheme = "aiusage-storetest"

    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var cancelledByApp = false

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// Starts the session (call on the main thread). `onEnd` gets a description, on the main thread,
    /// when the window closes for any reason other than `finish()`.
    func start(url: URL, onEnd: @escaping (String) -> Void) -> Bool {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { [weak self] callback, error in
            let text: String
            if let callback {
                text = "ended with a callback to \(callback.scheme ?? "?")://\(callback.host ?? "")"
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                text = "the sign-in window was closed"
            } else if let error {
                text = "the sign-in window failed: \(error.localizedDescription)"
            } else {
                text = "the sign-in window ended"
            }
            DispatchQueue.main.async {
                guard let self, !self.cancelledByApp else { return }
                onEnd(text)
            }
        }
        session.presentationContextProvider = self
        // Share the browser's cookies, so someone already signed in to ChatGPT there only confirms.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        cancelledByApp = false
        return session.start()
    }

    /// Codex says the sign-in is done: close the window (call on the main thread).
    func finish() {
        cancelledByApp = true
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
