import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Keeps keys and tokens. The app stores them in the macOS Keychain; tests
/// use `MemorySecretStore`. Nothing secret is written to a take folder.
public protocol AISecretStore: Sendable {
    func read(_ name: String) -> Data?
    func write(_ data: Data, for name: String) throws
    func delete(_ name: String)
}

public final class MemorySecretStore: AISecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ name: String) -> Data? { lock.withLock { items[name] } }
    public func write(_ data: Data, for name: String) throws { lock.withLock { items[name] = data } }
    public func delete(_ name: String) { lock.withLock { items[name] = nil } }
}

/// Secret names, so every part of the app reads the same Keychain items.
public enum AISecretName {
    public static let chatGPT = "chatgpt-credentials"
    public static let chatGPTHostID = "chatgpt-host-id"
    public static let chatGPTClientID = "chatgpt-client-id"
    public static let openAIKey = "openai-api-key"
    public static let anthropicKey = "anthropic-api-key"
    public static let openRouterKey = "openrouter-api-key"
}

public extension AISecretStore {
    func string(_ name: String) -> String? {
        read(name).map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    func setString(_ value: String?, for name: String) throws {
        if let value, !value.isEmpty { try write(Data(value.utf8), for: name) } else { delete(name) }
    }
}

/// Sign in with ChatGPT for an open source app that runs on the user's Mac
/// (developers.openai.com/siwc/token-sharing-open-source/sign-in): system
/// browser, loopback callback on 127.0.0.1, PKCE, no client secret.
/// The first sign-in registers this Mac with `dynamic_agent_client` and an
/// `ext_agent_host_id` we keep; OpenAI hands back the client id to reuse.
public enum ChatGPTAuth {
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let dynamicClientID = "dynamic_agent_client"
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let appName = "Vision One"
    public static let callbackPath = "/auth/callback"

    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public let challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            self.challenge = ChatGPTAuth.challenge(for: verifier)
        }

        public static func random() -> PKCE { PKCE(verifier: ChatGPTAuth.randomToken(bytes: 32)) }
    }

    /// One sign-in attempt: fresh state, nonce and PKCE each time.
    public struct Attempt: Sendable {
        public let state: String
        public let nonce: String
        public let pkce: PKCE
        public let redirectURI: String
        public let clientID: String

        public init(port: UInt16, clientID: String?, state: String = ChatGPTAuth.randomToken(bytes: 16),
                    nonce: String = ChatGPTAuth.randomToken(bytes: 16), pkce: PKCE = .random()) {
            self.state = state
            self.nonce = nonce
            self.pkce = pkce
            self.redirectURI = "http://127.0.0.1:\(port)\(ChatGPTAuth.callbackPath)"
            self.clientID = clientID ?? ChatGPTAuth.dynamicClientID
        }

        public var isFirstRegistration: Bool { clientID == ChatGPTAuth.dynamicClientID }
    }

    public static func authorizationURL(for attempt: Attempt, hostID: String, loginHint: String? = nil,
                                        idTokenHint: String? = nil) -> URL {
        var items = [
            URLQueryItem(name: "client_id", value: attempt.clientID),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: attempt.redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "nonce", value: attempt.nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: attempt.pkce.challenge),
        ]
        if attempt.isFirstRegistration { items.append(URLQueryItem(name: "agent_name_hint", value: appName)) }
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        if let idTokenHint { items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }

    public struct Callback: Equatable, Sendable {
        public let code: String
        /// The client id OpenAI issued on first registration, to save.
        public let issuedClientID: String?
    }

    public enum AuthError: Error, Equatable, Sendable {
        case wrongState
        case denied(String)
        case missingCode
        case noPlanAccess
        case badToken(String)
        case http(Int, String)
    }

    /// Reads the loopback callback (`/auth/callback?code=...&state=...`).
    public static func parseCallback(_ url: URL, attempt: Attempt) throws -> Callback {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw AuthError.denied(value("error_description") ?? error) }
        guard value("state") == attempt.state else { throw AuthError.wrongState }
        guard let code = value("code"), !code.isEmpty else { throw AuthError.missingCode }
        let issued = value("client_id").flatMap { $0 == dynamicClientID ? nil : $0 }
        return Callback(code: code, issuedClientID: issued)
    }

    public static func tokenRequest(code: String, clientID: String, attempt: Attempt) -> URLRequest {
        form(["grant_type": "authorization_code", "client_id": clientID, "code": code,
              "code_verifier": attempt.pkce.verifier, "redirect_uri": attempt.redirectURI, "resource": resource])
    }

    public static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        form(["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken,
              "resource": resource])
    }

    static func form(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        return request
    }

    struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
        var expires_in: Double?
        var scope: String?
    }

    /// Turns a token response into saved credentials. Checks the ID token's
    /// issuer, audience and nonce (it came straight from the token endpoint
    /// over TLS, which OpenID Connect accepts in place of a signature check)
    /// and that plan usage was granted.
    public static func credentials(from data: Data, clientID: String, nonce: String?,
                                   previous: ChatGPTCredentials? = nil, now: Date = Date()) throws -> ChatGPTCredentials {
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.badToken(errorMessage(from: data))
        }
        let idToken = token.id_token ?? previous?.idToken
        var email = previous?.email
        if let idToken, let claims = jwtClaims(idToken) {
            if let iss = claims["iss"] as? String, !iss.hasPrefix(issuer) { throw AuthError.badToken("issuer") }
            let aud = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
            if !aud.isEmpty, !aud.contains(clientID) { throw AuthError.badToken("audience") }
            if token.id_token != nil, let nonce, let tokenNonce = claims["nonce"] as? String, tokenNonce != nonce {
                throw AuthError.badToken("nonce")
            }
            email = (claims["email"] as? String) ?? email
        }
        let scopes = (token.scope ?? previous?.scopes.joined(separator: " ") ?? "").split(separator: " ").map(String.init)
        guard scopes.contains(planScope) else { throw AuthError.noPlanAccess }
        return ChatGPTCredentials(clientID: clientID, accessToken: token.access_token,
                                  refreshToken: token.refresh_token ?? previous?.refreshToken,
                                  idToken: idToken, email: email, scopes: scopes,
                                  expiresAt: now.addingTimeInterval(token.expires_in ?? 3600), savedAt: now)
    }

    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func randomToken(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    static func challenge(for verifier: String) -> String {
        #if canImport(CryptoKit)
        return base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        #else
        fatalError("Sign in with ChatGPT needs CryptoKit")
        #endif
    }
}

public struct ChatGPTCredentials: Codable, Equatable, Sendable {
    public var clientID: String
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var email: String?
    public var scopes: [String]
    public var expiresAt: Date
    public var savedAt: Date

    public var canUsePlan: Bool { scopes.contains(ChatGPTAuth.planScope) }

    /// Refresh a minute early so a request never starts with a dying token.
    public func needsRefresh(now: Date = Date()) -> Bool { now.addingTimeInterval(60) >= expiresAt }
}

/// The signed-in ChatGPT account: hands out access tokens, refreshing them
/// with the rotating refresh token, and keeps everything in the secret store.
public actor ChatGPTSession: AIAccessTokenSource {
    private let store: any AISecretStore
    private let http: any HTTPClient
    private var credentials: ChatGPTCredentials?

    public init(store: any AISecretStore, http: any HTTPClient = URLSessionHTTPClient()) {
        self.store = store
        self.http = http
        self.credentials = store.read(AISecretName.chatGPT).flatMap {
            try? Self.decoder.decode(ChatGPTCredentials.self, from: $0)
        }
    }

    public var account: String? { credentials?.email }
    public var isSignedIn: Bool { credentials?.canUsePlan == true }

    /// The id that registers this Mac, made once and kept, even after
    /// signing out, as the docs ask.
    public func hostID() -> String {
        if let id = store.string(AISecretName.chatGPTHostID) { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        try? store.setString(id, for: AISecretName.chatGPTHostID)
        return id
    }

    /// The client id OpenAI issued at first registration, if any.
    public func clientID() -> String? { store.string(AISecretName.chatGPTClientID) }

    public func newAttempt(port: UInt16) -> ChatGPTAuth.Attempt {
        ChatGPTAuth.Attempt(port: port, clientID: clientID())
    }

    public func authorizationURL(for attempt: ChatGPTAuth.Attempt) -> URL {
        ChatGPTAuth.authorizationURL(for: attempt, hostID: hostID(), loginHint: credentials?.email,
                                     idTokenHint: credentials?.idToken)
    }

    /// Finishes sign-in from the loopback callback URL.
    public func finish(callback url: URL, attempt: ChatGPTAuth.Attempt) async throws {
        let callback = try ChatGPTAuth.parseCallback(url, attempt: attempt)
        let clientID = callback.issuedClientID ?? attempt.clientID
        // Saved before the exchange so a retry reuses the registration.
        if callback.issuedClientID != nil { try store.setString(clientID, for: AISecretName.chatGPTClientID) }
        let (data, response) = try await http.send(ChatGPTAuth.tokenRequest(code: callback.code, clientID: clientID,
                                                                             attempt: attempt))
        guard (200..<300).contains(response.statusCode) else {
            throw ChatGPTAuth.AuthError.http(response.statusCode, errorMessage(from: data))
        }
        try save(ChatGPTAuth.credentials(from: data, clientID: clientID, nonce: attempt.nonce))
    }

    public func accessToken() async throws -> String? {
        guard let current = credentials, current.canUsePlan else { return nil }
        guard current.needsRefresh() else { return current.accessToken }
        guard let refresh = current.refreshToken else { return nil }
        let (data, response) = try await http.send(ChatGPTAuth.refreshRequest(refreshToken: refresh,
                                                                               clientID: current.clientID))
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 || response.statusCode == 401 { signOut() }
            return nil
        }
        let renewed = try ChatGPTAuth.credentials(from: data, clientID: current.clientID, nonce: nil, previous: current)
        try save(renewed)
        return renewed.accessToken
    }

    /// Forgets the tokens but keeps the host and client ids.
    public func signOut() {
        credentials = nil
        store.delete(AISecretName.chatGPT)
    }

    private func save(_ new: ChatGPTCredentials) throws {
        credentials = new
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try store.write(encoder.encode(new), for: AISecretName.chatGPT)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
