import Foundation
import Network

enum AuthCallbackError: Error {
    case startFailed
    case timedOut
    case tooManyAttempts
}

/// One-shot loopback HTTP listener for the OAuth authorization callback.
///
/// The listener binds to IPv4 loopback only, accepts the first request whose
/// `state` matches, and never reflects request data back to the browser.
final class AuthCallbackServer: @unchecked Sendable {
    struct Callback {
        var code: String?
        var clientID: String?
        var error: String?
    }

    private static let callbackPath = "/auth/callback"
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumConnections = 32
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let successBody = "Sign-in response received. You may return to Quick Chat."
    private static let failureBody = "Sign-in could not be verified. Return to Quick Chat and try again."

    private let expectedState: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "QuickChat.AuthCallback")

    private var listener: NWListener?
    private var timeoutItem: DispatchWorkItem?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<Callback, Error>?
    private var startValue: String?
    private var callbackValue: Callback?
    private var terminalError: Error?
    private var finished = false
    private var started = false
    private var startRequested = false
    private var waitRequested = false
    private var connectionCount = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(expectedState: String, timeout: TimeInterval) {
        self.expectedState = expectedState
        self.timeout = timeout
    }

    /// Starts listening and returns the exact redirect URI for the browser.
    func start() async throws -> String {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.queue.async {
                    if let value = self.startValue {
                        self.startValue = nil
                        continuation.resume(returning: value)
                        return
                    }
                    if self.finished {
                        continuation.resume(throwing: self.terminalError ?? AuthCallbackError.startFailed)
                        return
                    }
                    guard !self.startRequested else {
                        continuation.resume(throwing: AuthCallbackError.startFailed)
                        return
                    }
                    self.startRequested = true
                    self.startContinuation = continuation
                    self.beginListening()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Waits for the browser callback. Honours task cancellation.
    func wait() async throws -> Callback {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, Error>) in
                self.queue.async {
                    if self.finished {
                        if let callback = self.callbackValue {
                            self.callbackValue = nil
                            continuation.resume(returning: callback)
                        } else {
                            continuation.resume(throwing: self.terminalError ?? AuthCallbackError.startFailed)
                        }
                        return
                    }
                    guard !self.waitRequested else {
                        continuation.resume(throwing: AuthCallbackError.startFailed)
                        return
                    }
                    self.waitRequested = true
                    self.callbackContinuation = continuation
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        queue.async {
            self.terminateLocked(CancellationError())
        }
    }

    // MARK: - Listener

    private func beginListening() {
        guard !finished, listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            terminateLocked(AuthCallbackError.startFailed)
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async { self.becameReady(listener) }
            case .failed, .cancelled:
                self.queue.async { self.terminateLocked(AuthCallbackError.startFailed) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.queue.async { self.acceptLocked(connection) }
        }

        let item = DispatchWorkItem { [weak self] in
            self?.terminateLocked(AuthCallbackError.timedOut)
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + timeout, execute: item)
        listener.start(queue: queue)
    }

    private func becameReady(_ listener: NWListener) {
        guard !finished, !started else { return }
        guard let port = listener.port else {
            terminateLocked(AuthCallbackError.startFailed)
            return
        }
        started = true
        let redirectURI = "http://127.0.0.1:\(port.rawValue)\(Self.callbackPath)"
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(returning: redirectURI)
        } else {
            startValue = redirectURI
        }
    }

    private func terminateLocked(_ error: Error) {
        guard !finished else { return }
        finished = true
        terminalError = error
        timeoutItem?.cancel()
        timeoutItem = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        finishConnections(keeping: nil)
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: error)
        }
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    private func deliverLocked(_ callback: Callback, keeping selected: NWConnection?) {
        guard !finished else { return }
        finished = true
        timeoutItem?.cancel()
        timeoutItem = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        finishConnections(keeping: selected)
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(returning: callback)
        } else {
            callbackValue = callback
        }
    }

    private func untrack(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func finishConnections(keeping selected: NWConnection?) {
        let all = connections
        connections.removeAll()
        for (identifier, connection) in all {
            if let selected, ObjectIdentifier(selected) == identifier {
                connections[identifier] = connection
                continue
            }
            connection.cancel()
        }
    }

    // MARK: - Requests

    private func acceptLocked(_ connection: NWConnection) {
        guard !finished, Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connectionCount += 1
        guard connectionCount <= Self.maximumConnections else {
            connection.cancel()
            terminateLocked(AuthCallbackError.tooManyAttempts)
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            guard buffer.count <= Self.maximumHeaderBytes else {
                self.respond(connection, status: "400 Bad Request", body: Self.failureBody)
                return
            }
            if let terminator = buffer.range(of: Self.headerTerminator) {
                self.handle(header: buffer.subdata(in: 0..<terminator.lowerBound), connection: connection)
                return
            }
            guard !isComplete, error == nil else {
                self.respond(connection, status: "400 Bad Request", body: Self.failureBody)
                return
            }
            self.readRequest(connection, buffer: buffer)
        }
    }

    private func handle(header: Data, connection: NWConnection) {
        guard !finished else {
            connection.cancel()
            return
        }
        guard let text = String(data: header, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first,
              !line.isEmpty else {
            respond(connection, status: "400 Bad Request", body: Self.failureBody)
            return
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              String(fields[0]) == "GET",
              String(fields[2]).hasPrefix("HTTP/1.") else {
            respond(connection, status: "400 Bad Request", body: Self.failureBody)
            return
        }
        let target = String(fields[1])
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let callbackPath = pieces.first, String(callbackPath) == Self.callbackPath else {
            respond(connection, status: "400 Bad Request", body: Self.failureBody)
            return
        }
        let query = pieces.count == 2 ? String(pieces[1]) : ""
        guard let parameters = parseQuery(query) else {
            respond(connection, status: "400 Bad Request", body: Self.failureBody)
            return
        }
        let states = parameters["state"] ?? []
        guard states.count == 1,
              !states[0].isEmpty,
              constantTimeEqual(states[0], expectedState) else {
            respond(connection, status: "400 Bad Request", body: Self.failureBody)
            return
        }

        let errors = parameters["error"] ?? []
        if errors.count > 1 {
            respond(connection, status: "200 OK", body: Self.successBody)
            deliverLocked(Callback(code: nil, clientID: nil, error: "invalid_oauth_error"), keeping: connection)
            return
        }
        if errors.count == 1, !errors[0].isEmpty {
            respond(connection, status: "200 OK", body: Self.successBody)
            deliverLocked(Callback(code: nil, clientID: nil, error: errors[0]), keeping: connection)
            return
        }

        let codes = parameters["code"] ?? []
        let clientIDs = parameters["client_id"] ?? []
        guard codes.count == 1,
              !codes[0].isEmpty,
              clientIDs.count <= 1 else {
            respond(connection, status: "200 OK", body: Self.successBody)
            deliverLocked(Callback(code: nil, clientID: nil, error: "invalid_callback"), keeping: connection)
            return
        }
        respond(connection, status: "200 OK", body: Self.successBody)
        deliverLocked(Callback(code: codes[0], clientID: clientIDs.first, error: nil), keeping: connection)
    }

    private func parseQuery(_ query: String) -> [String: [String]]? {
        var parameters: [String: [String]] = [:]
        guard !query.isEmpty else { return parameters }
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { continue }
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = percentDecode(String(parts[0])), !key.isEmpty else { return nil }
            let rawValue = parts.count == 2 ? String(parts[1]) : ""
            guard let value = percentDecode(rawValue) else { return nil }
            parameters[key, default: []].append(value)
        }
        return parameters
    }

    private func percentDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        guard !finished else {
            untrack(connection)
            connection.cancel()
            return
        }
        let bodyData = Data(body.utf8)
        var response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8
        )
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.queue.async {
                self?.untrack(connection)
            }
            connection.cancel()
        })
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<leftBytes.count {
            difference |= leftBytes[index] ^ rightBytes[index]
        }
        return difference == 0
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback
        case .name(let name, _):
            return name.lowercased() == "localhost"
        @unknown default:
            return false
        }
    }
}
