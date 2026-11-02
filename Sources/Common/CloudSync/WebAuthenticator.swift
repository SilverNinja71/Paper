import Foundation

#if canImport(AuthenticationServices)
import AuthenticationServices

/// Real sign-in UI: the system's secure browser sheet (`ASWebAuthenticationSession`), identical API on macOS
/// and iOS/iPadOS. The app passes a closure that returns the window the sheet should appear over.
///
///     let authenticator = SystemWebAuthenticator { NSApp.keyWindow ?? NSApp.windows[0] }   // macOS
///     let authenticator = SystemWebAuthenticator { UIApplication.shared.connectedScenes ... .keyWindow! }   // iOS
public struct SystemWebAuthenticator: WebAuthenticator {
    public typealias AnchorProvider = @MainActor @Sendable () -> ASPresentationAnchor

    private let anchorProvider: AnchorProvider
    private let prefersEphemeralSession: Bool

    /// - Parameter prefersEphemeralSession: true = never share cookies with Safari (user must type the password
    ///   every time). The default (false) lets the user pick an account they are already signed in to.
    public init(prefersEphemeralSession: Bool = false, anchor: @escaping AnchorProvider) {
        self.anchorProvider = anchor
        self.prefersEphemeralSession = prefersEphemeralSession
    }

    public func authenticate(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        let anchor = anchorProvider
        let ephemeral = prefersEphemeralSession
        return try await SessionRunner().run(url: authorizationURL, scheme: callbackURLScheme,
                                             ephemeral: ephemeral, anchor: anchor)
    }
}

@MainActor
private final class SessionRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var anchor: SystemWebAuthenticator.AnchorProvider?

    func run(url: URL, scheme: String, ephemeral: Bool,
             anchor: @escaping SystemWebAuthenticator.AnchorProvider) async throws -> URL {
        self.anchor = anchor
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CloudError.signInCancelled)
                } else {
                    continuation.resume(throwing: CloudError.authenticationFailed(error?.localizedDescription ?? "unknown error"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = ephemeral
            self.session = session
            if !session.start() {
                continuation.resume(throwing: CloudError.authenticationFailed("The sign-in window could not be shown."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let anchor else { return ASPresentationAnchor() }
        return anchor()
    }
}
#endif
