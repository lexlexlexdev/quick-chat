import Foundation
import Testing
@testable import QuickChat

@Test func loopbackCallbackRejectsForeignStateWithoutConsumingSignIn() async throws {
    let server = AuthCallbackServer(expectedState: "expected-state", timeout: 5)
    defer { server.cancel() }
    let redirect = try await server.start()
    let base = try #require(URL(string: redirect))
    #expect(base.host == "127.0.0.1")
    #expect(base.path == "/auth/callback")

    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func request(state: String, code: String) async throws -> Int? {
        var parts = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
        parts.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: "oaiapp_test")
        ]
        let url = try #require(parts.url)
        let (_, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 3))
        return (response as? HTTPURLResponse)?.statusCode
    }

    #expect(try await request(state: "foreign", code: "wrong") == 400)
    #expect(try await request(state: "expected-state", code: "valid") == 200)
    let callback = try await server.wait()
    #expect(callback.code == "valid")
    #expect(callback.clientID == "oaiapp_test")
    #expect(callback.error == nil)
}

@Test func cancellingLoopbackCallbackDoesNotWaitForTimeout() async throws {
    let server = AuthCallbackServer(expectedState: "expected-state", timeout: 5)
    defer { server.cancel() }
    _ = try await server.start()
    let wait = Task { try await server.wait() }
    wait.cancel()
    await #expect(throws: CancellationError.self) { try await wait.value }
}
