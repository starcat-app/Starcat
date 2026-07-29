//
//  ProjectAccessOAuthServiceTests.swift
//  StarcatTests
//
//  验证 GitHub App 安装期间 OAuth 回调、state 防伪和凭据刷新契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ProjectAccessOAuthService", .serialized)
struct ProjectAccessOAuthServiceTests {
    private let oauthURL = URL(string: "https://github.test.invalid")!
    private let callbackURL = URL(string: "starcat://github-app/callback")!
    private let fixedNow = Date(timeIntervalSince1970: 1_000)

    private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
    }

    private func service(
        clientID: String = "Iv1.client",
        clientSecret: String = "secret",
        session: URLSession = .shared
    ) -> ProjectAccessOAuthService {
        ProjectAccessOAuthService(
            clientID: clientID,
            clientSecret: clientSecret,
            appSlug: "starcat-for-github",
            callbackURL: callbackURL,
            session: session,
            oauthBaseURL: oauthURL,
            apiBaseURL: oauthURL,
            now: { fixedNow },
            stateGenerator: { "fixed-state" }
        )
    }

    @Test("缺少 GitHub App Client Secret 时拒绝发起授权")
    func missingConfiguration() async {
        let service = service(clientSecret: "")

        await #expect(throws: ProjectAccessOAuthError.configurationMissing) {
            try await service.beginAuthorization(mode: .installation)
        }
    }

    @Test("安装入口携带一次性 state")
    func installationURLCarriesState() async throws {
        let info = try await service().beginAuthorization(mode: .installation)
        let components = try #require(
            URLComponents(url: info.authorizationURL, resolvingAgainstBaseURL: false)
        )

        #expect(info.authorizationURL.path == "/apps/starcat-for-github/installations/new")
        #expect(components.queryItems == [URLQueryItem(name: "state", value: "fixed-state")])
        #expect(info.expiresAt == fixedNow.addingTimeInterval(900))
    }

    @Test("重新连接使用明确的 GitHub App OAuth 地址")
    func reauthorizationURLCarriesCallbackAndState() async throws {
        let info = try await service().beginAuthorization(mode: .reauthorization)
        let components = try #require(
            URLComponents(url: info.authorizationURL, resolvingAgainstBaseURL: false)
        )
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )

        #expect(info.authorizationURL.path == "/login/oauth/authorize")
        #expect(parameters["client_id"] == "Iv1.client")
        #expect(parameters["redirect_uri"] == callbackURL.absoluteString)
        #expect(parameters["state"] == "fixed-state")
    }

    @Test("合法回调用 code 和 Client Secret 换取可刷新凭据")
    func callbackReturnsCredential() async throws {
        URLProtocolStub.reset()
        let bodies = RequestBodyRecorder()
        URLProtocolStub.requestHandler = { request in
            bodies.record(request)
            return (
                response(request),
                Data(
                    """
                    {
                      "access_token":"ghu_access",
                      "expires_in":28800,
                      "refresh_token":"ghr_refresh",
                      "refresh_token_expires_in":15897600
                    }
                    """.utf8
                )
            )
        }
        let service = service(session: URLProtocolStub.ephemeralSession())
        _ = try await service.beginAuthorization(mode: .installation)

        let credential = try await service.exchangeCallback(
            URL(string: "starcat://github-app/callback?code=one-time-code&state=fixed-state")!
        )

        #expect(credential.accessToken == "ghu_access")
        #expect(credential.refreshToken == "ghr_refresh")
        #expect(credential.accessExpiresAt == fixedNow.addingTimeInterval(28_800))
        #expect(credential.refreshExpiresAt == fixedNow.addingTimeInterval(15_897_600))

        let body = try #require(bodies.values.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["client_id"] == "Iv1.client")
        #expect(json["client_secret"] == "secret")
        #expect(json["code"] == "one-time-code")
        #expect(json["redirect_uri"] == callbackURL.absoluteString)
        #expect(json["device_code"] == nil)
    }

    @Test("伪造 state 被拒绝且不发 token 请求")
    func stateMismatchIsRejected() async throws {
        URLProtocolStub.reset()
        let counter = LockedCounter()
        URLProtocolStub.requestHandler = { request in
            _ = counter.increment()
            return (response(request), Data(#"{"access_token":"unexpected"}"#.utf8))
        }
        let service = service(session: URLProtocolStub.ephemeralSession())
        _ = try await service.beginAuthorization(mode: .installation)

        await #expect(throws: ProjectAccessOAuthError.stateMismatch) {
            try await service.exchangeCallback(
                URL(string: "starcat://github-app/callback?code=stolen&state=wrong")!
            )
        }
        #expect(counter.value == 0)
    }

    @Test("错误 callback host 不会进入 token 交换")
    func wrongCallbackRouteIsRejected() async throws {
        let service = service()
        _ = try await service.beginAuthorization(mode: .installation)

        await #expect(throws: ProjectAccessOAuthError.invalidCallback) {
            try await service.exchangeCallback(
                URL(string: "starcat://callback?code=login-code&state=fixed-state")!
            )
        }
    }

    @Test("用户拒绝授权映射为稳定状态")
    func accessDeniedIsMapped() async throws {
        let service = service()
        _ = try await service.beginAuthorization(mode: .installation)

        await #expect(throws: ProjectAccessOAuthError.userDeclined) {
            try await service.exchangeCallback(
                URL(string: "starcat://github-app/callback?error=access_denied&state=fixed-state")!
            )
        }
    }

    @Test("伪造拒绝回调不会清空合法授权上下文")
    func forgedDenialDoesNotResetFlow() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (
                response(request),
                Data(#"{"access_token":"ghu_after_forged_denial"}"#.utf8)
            )
        }
        let service = service(session: URLProtocolStub.ephemeralSession())
        _ = try await service.beginAuthorization(mode: .installation)

        await #expect(throws: ProjectAccessOAuthError.stateMismatch) {
            try await service.exchangeCallback(
                URL(
                    string:
                        "starcat://github-app/callback?error=access_denied&state=forged-state"
                )!
            )
        }
        let credential = try await service.exchangeCallback(
            URL(
                string:
                    "starcat://github-app/callback?code=legitimate-code&state=fixed-state"
            )!
        )

        #expect(credential.accessToken == "ghu_after_forged_denial")
    }

    @Test("刷新请求携带 Client Secret 并轮换 refresh token")
    func refreshUsesClientSecret() async throws {
        URLProtocolStub.reset()
        let bodies = RequestBodyRecorder()
        URLProtocolStub.requestHandler = { request in
            bodies.record(request)
            return (
                response(request),
                Data(
                    #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600}"#.utf8
                )
            )
        }
        let service = service(session: URLProtocolStub.ephemeralSession())

        let credential = try await service.refreshCredential(using: "ghr_old")

        #expect(credential.accessToken == "ghu_new")
        #expect(credential.refreshToken == "ghr_new")
        let body = try #require(bodies.values.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["client_id"] == "Iv1.client")
        #expect(json["client_secret"] == "secret")
        #expect(json["grant_type"] == "refresh_token")
        #expect(json["refresh_token"] == "ghr_old")
    }

    @Test("bad_refresh_token 映射为重新授权状态")
    func badRefreshToken() async {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (response(request), Data(#"{"error":"bad_refresh_token"}"#.utf8))
        }
        let service = service(session: URLProtocolStub.ephemeralSession())

        await #expect(throws: ProjectAccessOAuthError.badRefreshToken) {
            try await service.refreshCredential(using: "expired")
        }
    }

    @Test("断开连接撤销整个 GitHub App grant")
    func revokeAuthorizationDeletesGrant() async throws {
        URLProtocolStub.reset()
        let requests = URLRequestRecorder()
        let bodies = RequestBodyRecorder()
        URLProtocolStub.requestHandler = { request in
            requests.record(request)
            bodies.record(request)
            return (response(request, status: 204), Data())
        }
        let service = service(session: URLProtocolStub.ephemeralSession())

        try await service.revokeAuthorization(accessToken: "ghu_current")

        let request = try #require(requests.values.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/applications/Iv1.client/grant")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization == "Basic \(Data("Iv1.client:secret".utf8).base64EncodedString())")
        let body = try #require(bodies.values.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["access_token"] == "ghu_current")
    }

    @Test("远端 grant 已不存在时断开保持幂等")
    func missingGrantIsSuccessful() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (response(request, status: 404), Data())
        }
        let service = service(session: URLProtocolStub.ephemeralSession())

        try await service.revokeAuthorization(accessToken: "ghu_already_revoked")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

/// URLSession 可能把 `httpBody` 内部化为 `httpBodyStream`；测试在 handler 内读取，
/// 避免把 Foundation 的存储细节误判为业务没有发送 JSON。
private final class RequestBodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func record(_ request: URLRequest) {
        guard let data = request.httpBody ?? Self.read(request.httpBodyStream) else { return }
        lock.withLock {
            storage.append(data)
        }
    }

    var values: [Data] {
        lock.withLock { storage }
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }
}

private final class URLRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock {
            storage.append(request)
        }
    }

    var values: [URLRequest] {
        lock.withLock { storage }
    }
}
