import CryptoKit
import Foundation
import Security

/// Sign-in failures surfaced by `ChatGPTAuth`. Messages are safe to show and
/// never contain tokens, authorization codes, or key material.
enum ChatGPTAuthError: LocalizedError {
    case notSignedIn
    case planUnavailable
    case sessionExpired
    case refreshTooEarly
    case refreshFailed
    case network
    case signInDenied
    case signInInvalid
    case signInFailed
    case signInTimedOut
    case signInAlreadyInProgress
    case signInCouldNotStart
    case browserUnavailable
    case identityUnavailable
    case invalidIdentity
    case randomUnavailable
    case credentialStoreUnavailable
    case storedDataUnavailable
    case revocationUnconfirmed
    case responseUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with ChatGPT to use your plan."
        case .planUnavailable:
            return "ChatGPT plan access isn't available for this account. Reconnect in Settings and approve plan usage."
        case .sessionExpired:
            return "Your ChatGPT session expired. Sign in again."
        case .refreshTooEarly:
            return "ChatGPT asked Quick Chat to wait before refreshing. Try again shortly."
        case .refreshFailed:
            return "Quick Chat couldn't refresh your ChatGPT session. Try again later."
        case .network:
            return "Quick Chat couldn't reach ChatGPT. Check your connection and try again."
        case .signInDenied:
            return "ChatGPT sign-in wasn't authorized."
        case .signInInvalid:
            return "ChatGPT sign-in could not be verified. Try again."
        case .signInFailed:
            return "ChatGPT sign-in couldn't be completed. Try again."
        case .signInTimedOut:
            return "ChatGPT sign-in timed out. Try again."
        case .signInAlreadyInProgress:
            return "ChatGPT sign-in is already in progress."
        case .signInCouldNotStart:
            return "Quick Chat couldn't start ChatGPT sign-in. Try again."
        case .browserUnavailable:
            return "Quick Chat couldn't open a browser for ChatGPT sign-in."
        case .identityUnavailable:
            return "Quick Chat couldn't verify ChatGPT's sign-in response. Check your connection and try again."
        case .invalidIdentity:
            return "ChatGPT returned a sign-in that Quick Chat couldn't verify. Try again."
        case .randomUnavailable:
            return "Quick Chat couldn't start a secure sign-in. Try again."
        case .credentialStoreUnavailable:
            return "Quick Chat couldn't access its saved ChatGPT sign-in in Keychain. Check Keychain access and try again."
        case .storedDataUnavailable:
            return "Saved ChatGPT sign-in data is unavailable. Sign in again."
        case .revocationUnconfirmed:
            return "Signed out on this Mac, but ChatGPT didn't confirm revocation. Disconnect Quick Chat in ChatGPT settings."
        case .responseUnavailable:
            return "ChatGPT returned an unexpected response. Try again."
        }
    }
}

private enum AuthConfig {
    static let issuer = "https://auth.openai.com"
    static let authorizeURL = issuer + "/api/accounts/authorize"
    static let tokenURL = issuer + "/api/accounts/oauth/token"
    static let discoveryURL = issuer + "/.well-known/openid-configuration"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    static let agentName = "Quick Chat"
    static let dynamicClientID = "dynamic_agent_client"
    static let keychainService = "dev.quickchat.credentials"
    static let keychainAccount = "chatgpt"
    static let requestTimeout: TimeInterval = 20
    static let signInTimeout: TimeInterval = 5 * 60
    static let refreshSkew: TimeInterval = 5 * 60
    static let maxResponseBytes = 1 << 20
    static let maxVaultBytes = 64 << 10
    static let maxTokenLifetime: Int64 = 365 * 24 * 60 * 60
    static let revokeRequestTimeout: TimeInterval = 4
    static let signOutBudget: TimeInterval = 8
}

private let authTerminalRefreshCodes: Set<String> = [
    "invalid_grant",
    "invalid_refresh_token",
    "token_expired",
    "refresh_token_expired",
    "refresh_token_invalidated",
    "refresh_token_reused"
]

private struct AuthState: Codable {
    var version: Int
    var hostID: String
    var account: AuthAccount?
}

private struct AuthAccount: Codable {
    var issuer: String
    var clientID: String
    var subject: String
    var email: String?
    var scopes: [String]
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var tokenType: String?
    var expiresAt: Date?
    var earliestRefreshAt: Date?
}

private struct AuthDiscovery: Decodable {
    let issuer: String
    let jwksURI: String?
    let revocationEndpoint: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case jwksURI = "jwks_uri"
        case revocationEndpoint = "revocation_endpoint"
    }
}

private struct AuthJWKS: Decodable {
    let keys: [AuthJWK]
}

private struct AuthJWK: Decodable {
    let kty: String
    let kid: String?
    let alg: String?
    let use: String?
    let n: String?
    let e: String?
}

private struct AuthJWTHeader: Decodable {
    let alg: String
    let kid: String?
}

private struct AuthIDTokenClaims: Decodable {
    let iss: String
    let sub: String
    let aud: AuthAudience
    let exp: Double
    let iat: Double
    let nonce: String?
    let email: String?
}

private enum AuthAudience: Decodable {
    case single(String)
    case multiple([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .single(value)
            return
        }
        if let values = try? container.decode([String].self) {
            self = .multiple(values)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid audience claim")
    }

    func contains(_ value: String) -> Bool {
        switch self {
        case .single(let audience):
            return audience == value
        case .multiple(let audiences):
            return audiences.contains(value)
        }
    }
}

private struct AuthTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: Int64?
    let scope: String?
    let earliestRefreshAt: AuthTimestamp?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case earliestRefreshAt = "earliest_refresh_at"
    }
}

/// `earliest_refresh_at` has no documented wire format. Accept RFC 3339
/// strings, numeric strings, and JSON numbers, mirroring the reference.
private struct AuthTimestamp: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            date = nil
            return
        }
        if let text = try? container.decode(String.self) {
            date = Self.parse(text)
            return
        }
        if let number = try? container.decode(Double.self) {
            date = Self.fromUnix(number)
            return
        }
        date = nil
    }

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let value = formatter.date(from: text) {
            return value
        }
        if let seconds = Double(text) {
            return fromUnix(seconds)
        }
        return nil
    }

    private static func fromUnix(_ value: Double) -> Date? {
        guard value.isFinite, value >= 0, value <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

private struct AuthIssuedTokens {
    let accessToken: String
    let refreshToken: String?
    let idToken: String
    let tokenType: String
    let expiresIn: Int64
    let scope: String?
    let earliestRefreshAt: Date?
}

private struct AuthIdentity {
    let subject: String
    let email: String?
}

private enum AuthKeychainError: Error {
    case failed(OSStatus)
}

private enum AuthKeychain {
    static func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthConfig.keychainService,
            kSecAttrAccount as String: AuthConfig.keychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthKeychainError.failed(status)
        }
        return data
    }

    static func write(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthConfig.keychainService,
            kSecAttrAccount as String: AuthConfig.keychainAccount,
            kSecAttrSynchronizable as String: false
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AuthKeychainError.failed(updateStatus)
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw AuthKeychainError.failed(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw AuthKeychainError.failed(addStatus)
        }
    }
}

private final class AuthNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One ChatGPT account signed in through the documented local-app SIWC flow.
actor ChatGPTAuth {
    private let session: URLSession
    private var refreshInFlight: Task<AuthAccount, Error>?
    private var signInActive = false

    init() {
        let guardDelegate = AuthNoRedirects()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = AuthConfig.requestTimeout
        configuration.timeoutIntervalForResource = AuthConfig.requestTimeout + 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Display label (the account email when available) or nil when signed out.
    /// A saved registration with no tokens is signed out so Settings offers
    /// Continue and reuses that registration.
    func account() throws -> String? {
        let state = try loadState()
        guard let account = state.account else { return nil }
        let signedIn = account.accessToken?.isEmpty == false || account.refreshToken?.isEmpty == false
        guard signedIn else { return nil }
        return Self.displayName(for: account)
    }

    /// Runs a fresh ChatGPT dynamic-client registration, PKCE browser sign-in,
    /// loopback callback, and signed-identity validation. Returns the label.
    func signIn(openBrowser: @escaping @MainActor (URL) -> Bool) async throws -> String {
        guard !signInActive else { throw ChatGPTAuthError.signInAlreadyInProgress }
        signInActive = true
        defer { signInActive = false }
        try Task.checkCancellation()

        var state: AuthState
        do {
            state = try loadState()
        } catch ChatGPTAuthError.storedDataUnavailable {
            state = AuthState(version: 1, hostID: "", account: nil)
        }
        let existing = state.account
        let hostID = try ensureHostID(&state)
        let stateValue = try randomURLValue()
        let nonce = try randomURLValue()
        let verifier = try randomURLValue()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let server = AuthCallbackServer(expectedState: stateValue, timeout: AuthConfig.signInTimeout)
        defer { server.cancel() }

        let redirectURI: String
        do {
            redirectURI = try await server.start()
        } catch let error as AuthCallbackError {
            throw Self.callbackError(error)
        }
        let authorizationURL = try authorizationURL(
            clientID: existing?.clientID ?? AuthConfig.dynamicClientID,
            existing: existing,
            hostID: hostID,
            redirectURI: redirectURI,
            state: stateValue,
            nonce: nonce,
            challenge: challenge
        )

        let opened = await openBrowser(authorizationURL)
        guard opened else { throw ChatGPTAuthError.browserUnavailable }

        let callback: AuthCallbackServer.Callback
        do {
            callback = try await server.wait()
        } catch let error as AuthCallbackError {
            throw Self.callbackError(error)
        }
        if let error = callback.error, !error.isEmpty {
            throw error == "access_denied" ? ChatGPTAuthError.signInDenied : ChatGPTAuthError.signInInvalid
        }
        guard let code = callback.code, !code.isEmpty else {
            throw ChatGPTAuthError.signInInvalid
        }

        let issuedClientID: String
        if let existing {
            if let callbackClientID = callback.clientID, !callbackClientID.isEmpty,
               callbackClientID != existing.clientID {
                throw ChatGPTAuthError.signInInvalid
            }
            issuedClientID = existing.clientID
        } else {
            guard let callbackClientID = callback.clientID, !callbackClientID.isEmpty,
                  callbackClientID != AuthConfig.dynamicClientID else {
                throw ChatGPTAuthError.signInInvalid
            }
            issuedClientID = callbackClientID
        }

        let tokens = try await exchangeAuthorizationCode(
            clientID: issuedClientID,
            code: code,
            verifier: verifier,
            redirectURI: redirectURI
        )
        try Task.checkCancellation()
        let identity = try await verifyIdentityToken(tokens.idToken, clientID: issuedClientID, nonce: nonce)
        if let existing, identity.subject != existing.subject {
            throw ChatGPTAuthError.signInInvalid
        }

        let issued = AuthAccount(
            issuer: AuthConfig.issuer,
            clientID: issuedClientID,
            subject: identity.subject,
            email: identity.email,
            scopes: tokens.scope.map { Self.parseScopes($0) } ?? [],
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            tokenType: tokens.tokenType,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn)),
            earliestRefreshAt: tokens.earliestRefreshAt
        )

        var current = try loadState()
        current.account = issued
        try saveState(current)

        // A sign-in without the plan scope is retained, but `accessToken()`
        // refuses to produce a token until plan usage is granted.
        return Self.displayName(for: issued)
    }

    /// Returns a usable access token, refreshing it when needed.
    func accessToken() async throws -> String {
        try Task.checkCancellation()
        let state = try loadState()
        guard let account = state.account else { throw ChatGPTAuthError.notSignedIn }
        guard Self.hasPlanScope(account.scopes) else { throw ChatGPTAuthError.planUnavailable }

        let now = Date()
        if let earliest = account.earliestRefreshAt, earliest > now {
            if let token = account.accessToken, !token.isEmpty,
               let expiresAt = account.expiresAt, expiresAt > now {
                return token
            }
            throw ChatGPTAuthError.refreshTooEarly
        }
        if let token = account.accessToken, !token.isEmpty,
           let expiresAt = account.expiresAt,
           expiresAt > now.addingTimeInterval(AuthConfig.refreshSkew) {
            return token
        }
        guard account.refreshToken?.isEmpty == false else {
            throw ChatGPTAuthError.sessionExpired
        }

        let created: Bool
        let task: Task<AuthAccount, Error>
        if let existing = refreshInFlight {
            created = false
            task = existing
        } else {
            created = true
            task = Task { [account] in
                try await self.refresh(account: account)
            }
            refreshInFlight = task
        }

        let updated: AuthAccount
        do {
            updated = try await task.value
        } catch {
            if created {
                refreshInFlight = nil
            }
            throw error
        }
        if created {
            refreshInFlight = nil
        }
        guard updated.clientID == account.clientID, updated.subject == account.subject else {
            throw ChatGPTAuthError.notSignedIn
        }
        try Task.checkCancellation()
        guard Self.hasPlanScope(updated.scopes) else { throw ChatGPTAuthError.planUnavailable }
        guard let token = updated.accessToken, !token.isEmpty else {
            throw ChatGPTAuthError.sessionExpired
        }
        return token
    }

    /// Revokes the renewable session, then clears local tokens while retaining
    /// the issued client ID, verified subject, host ID, and email mapping.
    func signOut() async throws {
        let state: AuthState
        do {
            state = try loadState()
        } catch ChatGPTAuthError.storedDataUnavailable {
            try saveState(AuthState(version: 1, hostID: "", account: nil))
            return
        }
        guard let account = state.account else { return }
        refreshInFlight?.cancel()
        refreshInFlight = nil

        var revoked = true
        if let refreshToken = account.refreshToken, !refreshToken.isEmpty {
            revoked = try await revoke(refreshToken: refreshToken, clientID: account.clientID)
        }
        try Task.checkCancellation()

        // Sign-out keeps the issued client ID, verified subject, host ID, and
        // email mapping so Continue reauthorizes the same registration.
        try clearTokens(matching: account)
        if !revoked {
            throw ChatGPTAuthError.revocationUnconfirmed
        }
    }

    // MARK: - Sign-in helpers

    private static func callbackError(_ error: AuthCallbackError) -> Error {
        switch error {
        case .timedOut:
            return ChatGPTAuthError.signInTimedOut
        case .startFailed:
            return ChatGPTAuthError.signInCouldNotStart
        case .tooManyAttempts:
            return ChatGPTAuthError.signInInvalid
        }
    }

    private func authorizationURL(
        clientID: String,
        existing: AuthAccount?,
        hostID: String,
        redirectURI: String,
        state: String,
        nonce: String,
        challenge: String
    ) throws -> URL {
        guard var components = URLComponents(string: AuthConfig.authorizeURL) else {
            throw ChatGPTAuthError.signInCouldNotStart
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID)
        ]
        if let existing {
            if let idToken = existing.idToken, !idToken.isEmpty {
                items.append(URLQueryItem(name: "id_token_hint", value: idToken))
            }
            let email = existing.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !email.isEmpty {
                items.append(URLQueryItem(name: "login_hint", value: email))
            }
            if !Self.hasPlanScope(existing.scopes) {
                items.append(URLQueryItem(name: "prompt", value: "consent"))
            }
        } else {
            items.append(URLQueryItem(name: "agent_name_hint", value: AuthConfig.agentName))
        }
        items.append(contentsOf: [
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: AuthConfig.scopes),
            URLQueryItem(name: "resource", value: AuthConfig.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ])
        components.queryItems = items
        guard let url = components.url else { throw ChatGPTAuthError.signInCouldNotStart }
        return url
    }

    private func exchangeAuthorizationCode(
        clientID: String,
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> AuthIssuedTokens {
        let request = try formRequest(
            endpoint: AuthConfig.tokenURL,
            values: [
                ("grant_type", "authorization_code"),
                ("client_id", clientID),
                ("code", code),
                ("code_verifier", verifier),
                ("redirect_uri", redirectURI),
                ("resource", AuthConfig.resource)
            ],
            timeout: AuthConfig.requestTimeout
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw ChatGPTAuthError.signInFailed }
        guard let tokens = try? JSONDecoder().decode(AuthTokenResponse.self, from: data),
              let accessToken = tokens.accessToken, !accessToken.isEmpty,
              let idToken = tokens.idToken, !idToken.isEmpty,
              let expiresIn = tokens.expiresIn, expiresIn > 0,
              expiresIn <= AuthConfig.maxTokenLifetime,
              (tokens.tokenType ?? "").caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw ChatGPTAuthError.signInFailed
        }
        return AuthIssuedTokens(
            accessToken: accessToken,
            refreshToken: tokens.refreshToken,
            idToken: idToken,
            tokenType: tokens.tokenType ?? "Bearer",
            expiresIn: expiresIn,
            scope: tokens.scope,
            earliestRefreshAt: tokens.earliestRefreshAt?.date
        )
    }

    // MARK: - Identity validation

    private func verifyIdentityToken(_ rawToken: String, clientID: String, nonce: String) async throws -> AuthIdentity {
        guard !rawToken.isEmpty, !clientID.isEmpty else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let parts = rawToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Self.base64URLDecode(String(parts[0])),
              let claimsData = Self.base64URLDecode(String(parts[1])),
              let signature = Self.base64URLDecode(String(parts[2])),
              let header = try? JSONDecoder().decode(AuthJWTHeader.self, from: headerData),
              header.alg == "RS256",
              let keyID = header.kid, !keyID.isEmpty, keyID.utf8.count <= 256 else {
            throw ChatGPTAuthError.invalidIdentity
        }

        let discovery = try await fetchDiscovery()
        guard let jwksURL = Self.sameIssuerEndpoint(AuthConfig.issuer, discovery.jwksURI) else {
            throw ChatGPTAuthError.identityUnavailable
        }
        let keys = try await fetchJWKS(jwksURL)
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        let candidates = Self.rsaPublicKeyData(from: keys, keyID: keyID)
        guard !candidates.isEmpty else { throw ChatGPTAuthError.invalidIdentity }

        let signingInput = Data((String(parts[0]) + "." + String(parts[1])).utf8)
        var signatureValid = false
        for publicKeyData in candidates {
            guard let publicKey = SecKeyCreateWithData(
                publicKeyData as CFData,
                keyAttributes as CFDictionary,
                nil
            ) else {
                continue
            }
            if SecKeyVerifySignature(
                publicKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                signingInput as CFData,
                signature as CFData,
                nil
            ) {
                signatureValid = true
                break
            }
        }
        guard signatureValid else { throw ChatGPTAuthError.invalidIdentity }

        guard let claims = try? JSONDecoder().decode(AuthIDTokenClaims.self, from: claimsData) else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let now = Date().timeIntervalSince1970
        guard claims.iss == AuthConfig.issuer,
              claims.aud.contains(clientID),
              !claims.sub.isEmpty,
              claims.exp.isFinite, claims.iat.isFinite,
              claims.exp > 0, claims.iat > 0,
              claims.exp >= now - 5,
              claims.iat <= now + 5,
              claims.nonce == nonce else {
            throw ChatGPTAuthError.invalidIdentity
        }
        return AuthIdentity(subject: claims.sub, email: claims.email)
    }

    private func fetchDiscovery(timeout: TimeInterval = AuthConfig.requestTimeout) async throws -> AuthDiscovery {
        guard let url = URL(string: AuthConfig.discoveryURL) else {
            throw ChatGPTAuthError.identityUnavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              let document = try? JSONDecoder().decode(AuthDiscovery.self, from: data),
              document.issuer == AuthConfig.issuer else {
            throw ChatGPTAuthError.identityUnavailable
        }
        return document
    }

    private func fetchJWKS(_ url: URL) async throws -> [AuthJWK] {
        var request = URLRequest(url: url)
        request.timeoutInterval = AuthConfig.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              let document = try? JSONDecoder().decode(AuthJWKS.self, from: data) else {
            throw ChatGPTAuthError.identityUnavailable
        }
        return document.keys
    }

    // MARK: - Refresh

    private func refresh(account: AuthAccount) async throws -> AuthAccount {
        try Task.checkCancellation()
        if let earliest = account.earliestRefreshAt, earliest > Date() {
            throw ChatGPTAuthError.refreshTooEarly
        }
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTAuthError.sessionExpired
        }

        let request = try formRequest(
            endpoint: AuthConfig.tokenURL,
            values: [
                ("grant_type", "refresh_token"),
                ("client_id", account.clientID),
                ("refresh_token", refreshToken),
                ("resource", AuthConfig.resource)
            ],
            timeout: AuthConfig.requestTimeout
        )
        let (data, response) = try await send(request)

        guard response.statusCode == 200 else {
            let code = Self.responseErrorCode(data)
            if authTerminalRefreshCodes.contains(code.lowercased()) {
                try clearTokens(matching: account)
                throw ChatGPTAuthError.sessionExpired
            }
            throw ChatGPTAuthError.refreshFailed
        }
        guard let tokens = try? JSONDecoder().decode(AuthTokenResponse.self, from: data),
              let accessToken = tokens.accessToken, !accessToken.isEmpty,
              let newRefreshToken = tokens.refreshToken, !newRefreshToken.isEmpty,
              let expiresIn = tokens.expiresIn, expiresIn > 0,
              expiresIn <= AuthConfig.maxTokenLifetime,
              (tokens.tokenType ?? "").caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw ChatGPTAuthError.refreshFailed
        }

        var updated = account
        updated.accessToken = accessToken
        updated.refreshToken = newRefreshToken
        updated.tokenType = tokens.tokenType
        updated.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        if let scope = tokens.scope {
            updated.scopes = Self.parseScopes(scope)
        }
        if let earliest = tokens.earliestRefreshAt?.date {
            updated.earliestRefreshAt = earliest
        }

        // The rotated refresh token is persisted before returning, even if the
        // caller is cancelled, so a completed rotation is never lost.
        try persistRefreshed(updated, matching: account)
        return updated
    }

    private func persistRefreshed(_ updated: AuthAccount, matching account: AuthAccount) throws {
        var state = try loadState()
        guard let current = state.account,
              current.clientID == account.clientID,
              current.subject == account.subject else {
            throw ChatGPTAuthError.notSignedIn
        }
        state.account = updated
        try saveState(state)
    }

    private func clearTokens(matching account: AuthAccount) throws {
        var state = try loadState()
        guard let current = state.account,
              current.clientID == account.clientID,
              current.subject == account.subject else {
            throw ChatGPTAuthError.notSignedIn
        }
        var cleared = current
        cleared.accessToken = nil
        cleared.refreshToken = nil
        cleared.idToken = nil
        cleared.tokenType = nil
        cleared.expiresAt = nil
        cleared.earliestRefreshAt = nil
        state.account = cleared
        try saveState(state)
    }

    // MARK: - Revocation

    /// Revokes the renewable session per SIWC. An empty HTTP 200 is success.
    /// Only network failures and 5xx responses retry, with bounded timeouts
    /// and backoff; a definitive 4xx response stops immediately.
    private func revoke(refreshToken: String, clientID: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(AuthConfig.signOutBudget)
        for attempt in 0..<3 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.5 else { break }
            let perRequest = min(AuthConfig.revokeRequestTimeout, max(0.5, remaining / 2))
            do {
                let discovery = try await fetchDiscovery(timeout: perRequest)
                guard let endpoint = Self.sameIssuerEndpoint(AuthConfig.issuer, discovery.revocationEndpoint) else {
                    return false
                }
                let request = try formRequest(
                    endpoint: endpoint.absoluteString,
                    values: [
                        ("token", refreshToken),
                        ("token_type_hint", "refresh_token"),
                        ("client_id", clientID)
                    ],
                    timeout: perRequest
                )
                let (data, response) = try await send(request)
                if response.statusCode == 200, Self.isBlank(data) {
                    return true
                }
                if response.statusCode < 500 {
                    return false
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Network failures and provider failures are retried below.
            }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 100_000_000)
            }
        }
        return false
    }

    // MARK: - HTTP

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ChatGPTAuthError.responseUnavailable
            }
            if http.expectedContentLength > Int64(AuthConfig.maxResponseBytes) {
                throw ChatGPTAuthError.responseUnavailable
            }
            var data = Data()
            data.reserveCapacity(4096)
            for try await byte in bytes {
                data.append(byte)
                if data.count > AuthConfig.maxResponseBytes {
                    throw ChatGPTAuthError.responseUnavailable
                }
            }
            return (data, http)
        } catch let error as ChatGPTAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ChatGPTAuthError.network
        }
    }

    private func formRequest(
        endpoint: String,
        values: [(String, String)],
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else { throw ChatGPTAuthError.responseUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let body = values
            .map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    // MARK: - Storage

    private func loadState() throws -> AuthState {
        let data: Data?
        do {
            data = try AuthKeychain.read()
        } catch {
            throw ChatGPTAuthError.credentialStoreUnavailable
        }
        guard let data else {
            return AuthState(version: 1, hostID: "", account: nil)
        }
        guard data.count <= AuthConfig.maxVaultBytes,
              let state = try? JSONDecoder().decode(AuthState.self, from: data) else {
            throw ChatGPTAuthError.storedDataUnavailable
        }
        try validate(state)
        return state
    }

    private func saveState(_ state: AuthState) throws {
        try validate(state)
        guard let data = try? JSONEncoder().encode(state), data.count <= AuthConfig.maxVaultBytes else {
            throw ChatGPTAuthError.storedDataUnavailable
        }
        do {
            try AuthKeychain.write(data)
        } catch {
            throw ChatGPTAuthError.credentialStoreUnavailable
        }
    }

    private func validate(_ state: AuthState) throws {
        guard state.version == 1,
              state.hostID.isEmpty || Self.validHostID(state.hostID) else {
            throw ChatGPTAuthError.storedDataUnavailable
        }
        guard let account = state.account else { return }
        guard !state.hostID.isEmpty,
              account.issuer == AuthConfig.issuer,
              !account.clientID.isEmpty,
              account.clientID != AuthConfig.dynamicClientID,
              !account.subject.isEmpty,
              account.clientID.utf8.count <= 512,
              account.subject.utf8.count <= 512,
              (account.email?.utf8.count ?? 0) <= 320,
              account.scopes.count <= 64,
              account.scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw ChatGPTAuthError.storedDataUnavailable
        }
    }

    private func ensureHostID(_ state: inout AuthState) throws -> String {
        if !state.hostID.isEmpty {
            return state.hostID
        }
        state.hostID = "urn:uuid:" + UUID().uuidString.lowercased()
        try saveState(state)
        return state.hostID
    }

    // MARK: - Small helpers

    private func randomURLValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ChatGPTAuthError.randomUnavailable }
        return Self.base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder != 0 {
            text.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: text, options: [])
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func displayName(for account: AuthAccount) -> String {
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? "ChatGPT account" : email
    }

    private static func parseScopes(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in raw.split(whereSeparator: { $0.isWhitespace }) {
            let scope = String(item)
            if seen.insert(scope).inserted {
                result.append(scope)
            }
        }
        return result.sorted()
    }

    private static func hasPlanScope(_ scopes: [String]) -> Bool {
        scopes.contains(AuthConfig.planScope)
    }

    private static func responseErrorCode(_ data: Data) -> String {
        struct Envelope: Decodable { let error: String? }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let code = envelope.error else {
            return ""
        }
        return code
    }

    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    private static func validHostID(_ value: String) -> Bool {
        let prefix = "urn:uuid:"
        guard value.hasPrefix(prefix) else { return false }
        let text = String(value.dropFirst(prefix.count))
        guard text.count == 36, let parsed = UUID(uuidString: text) else { return false }
        guard parsed.uuidString.lowercased() == text.lowercased() else { return false }
        let bytes = withUnsafeBytes(of: parsed.uuid) { Array($0) }
        guard bytes.count == 16 else { return false }
        let version = bytes[6] >> 4
        let variant = bytes[8] >> 6
        return (1...8).contains(Int(version)) && variant == 2
    }

    private static func sameIssuerEndpoint(_ issuer: String, _ endpoint: String?) -> URL? {
        guard let endpoint,
              let base = URLComponents(string: issuer),
              let parsed = URLComponents(string: endpoint),
              base.scheme?.lowercased() == "https",
              base.scheme?.lowercased() == parsed.scheme?.lowercased(),
              let baseHost = base.host, let parsedHost = parsed.host,
              baseHost.lowercased() == parsedHost.lowercased(),
              base.port == parsed.port,
              parsed.user == nil,
              parsed.password == nil,
              parsed.fragment == nil,
              parsed.query == nil,
              !parsed.path.isEmpty,
              let url = parsed.url else {
            return nil
        }
        return url
    }

    private static func rsaPublicKeyData(from keys: [AuthJWK], keyID: String) -> [Data] {
        var candidates: [Data] = []
        for key in keys where key.kid == keyID {
            if let data = rsaPublicKeyData(from: key) {
                candidates.append(data)
            }
        }
        return candidates
    }

    private static func rsaPublicKeyData(from key: AuthJWK) -> Data? {
        guard key.kty == "RSA" else { return nil }
        if let algorithm = key.alg, algorithm != "RS256" { return nil }
        if let use = key.use, use != "sig" { return nil }
        guard let modulusText = key.n, let exponentText = key.e,
              let modulus = base64URLDecode(modulusText), !modulus.isEmpty, modulus.count <= 1024,
              let exponent = base64URLDecode(exponentText), !exponent.isEmpty, exponent.count <= 8 else {
            return nil
        }
        let body = derInteger(modulus) + derInteger(exponent)
        return derTag(0x30, body)
    }

    private static func derTag(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(derLength(content.count))
        result.append(content)
        return result
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(truncatingIfNeeded: value), at: 0)
            value >>= 8
        }
        return Data([UInt8(0x80) | UInt8(bytes.count)] + bytes)
    }

    private static func derInteger(_ value: Data) -> Data {
        var bytes = value
        while bytes.count > 1, bytes.first == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return derTag(0x02, bytes)
    }
}
