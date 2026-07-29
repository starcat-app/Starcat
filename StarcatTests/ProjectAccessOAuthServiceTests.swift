//
//  ProjectAccessOAuthServiceTests.swift
//  StarcatTests
//
//  验证 GitHub App Device Flow、轮询状态和无 client_secret 刷新契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ProjectAccessOAuthService", .serialized)
struct ProjectAccessOAuthServiceTests {
    private let oauthURL = URL(string: "https://github.test.invalid")!
    private let fixedNow = Date(timeIntervalSince1970: 1_000)

    private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
    }

    @Test("缺少 GitHub App Client ID 时拒绝发起授权")
    func missingConfiguration() async {
        let service = ProjectAccessOAuthService(clientID: "")
        await #expect(throws: ProjectAccessOAuthError.configurationMissing) {
            try await service.beginDeviceFlow()
        }
    }

    @Test("Device Flow 解析 user code 并轮询得到可刷新凭据")
    func deviceFlowReturnsCredential() async throws {
        URLProtocolStub.reset()
        let counter = LockedCounter()
        let bodies = RequestBodyRecorder()
        URLProtocolStub.requestHandler = { request in
            bodies.record(request)
            let call = counter.increment()
            if call == 1 {
                let body = Data(
                    """
                    {
                      "device_code":"device-secret",
                      "user_code":"ABCD-EFGH",
                      "verification_uri":"https://github.test.invalid/login/device",
                      "expires_in":900,
                      "interval":5
                    }
                    """.utf8
                )
                return (response(request), body)
            }
            let body = Data(
                """
                {
                  "access_token":"ghu_access",
                  "expires_in":28800,
                  "refresh_token":"ghr_refresh",
                  "refresh_token_expires_in":15897600,
                  "token_type":"bearer",
                  "scope":""
                }
                """.utf8
            )
            return (response(request), body)
        }
        let service = ProjectAccessOAuthService(
            clientID: "Iv1.public-client-id",
            session: URLProtocolStub.ephemeralSession(),
            oauthBaseURL: oauthURL,
            now: { fixedNow },
            sleep: { _ in }
        )

        let info = try await service.beginDeviceFlow()
        let credential = try await service.awaitCredential()

        #expect(info.userCode == "ABCD-EFGH")
        #expect(info.pollInterval == 5)
        #expect(credential.accessToken == "ghu_access")
        #expect(credential.refreshToken == "ghr_refresh")
        #expect(credential.accessExpiresAt == fixedNow.addingTimeInterval(28_800))
        #expect(credential.refreshExpiresAt == fixedNow.addingTimeInterval(15_897_600))

        let firstBody = try #require(bodies.values.first)
        let firstJSON = try #require(
            JSONSerialization.jsonObject(with: firstBody) as? [String: String]
        )
        #expect(firstJSON == ["client_id": "Iv1.public-client-id"])
    }

    @Test("authorization_pending 后继续轮询")
    func pendingContinuesPolling() async throws {
        URLProtocolStub.reset()
        let counter = LockedCounter()
        URLProtocolStub.requestHandler = { request in
            let call = counter.increment()
            if call == 1 {
                return (
                    response(request),
                    Data(
                        #"{"device_code":"d","user_code":"U","verification_uri":"https://github.test.invalid/device","expires_in":900,"interval":1}"#.utf8
                    )
                )
            }
            if call == 2 {
                return (response(request), Data(#"{"error":"authorization_pending"}"#.utf8))
            }
            return (response(request), Data(#"{"access_token":"ghu_ok"}"#.utf8))
        }
        let service = ProjectAccessOAuthService(
            clientID: "client",
            session: URLProtocolStub.ephemeralSession(),
            oauthBaseURL: oauthURL,
            now: { fixedNow },
            sleep: { _ in }
        )

        _ = try await service.beginDeviceFlow()
        let credential = try await service.awaitCredential()

        #expect(credential.accessToken == "ghu_ok")
        #expect(counter.value == 3)
    }

    @Test("刷新请求不携带 client secret 并轮换 refresh token")
    func refreshWithoutClientSecret() async throws {
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
        let service = ProjectAccessOAuthService(
            clientID: "client",
            session: URLProtocolStub.ephemeralSession(),
            oauthBaseURL: oauthURL,
            now: { fixedNow },
            sleep: { _ in }
        )

        let credential = try await service.refreshCredential(using: "ghr_old")

        #expect(credential.accessToken == "ghu_new")
        #expect(credential.refreshToken == "ghr_new")
        let body = try #require(bodies.values.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["client_id"] == "client")
        #expect(json["grant_type"] == "refresh_token")
        #expect(json["refresh_token"] == "ghr_old")
        #expect(json["client_secret"] == nil)
    }

    @Test("bad_refresh_token 映射为重新授权状态")
    func badRefreshToken() async {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (response(request), Data(#"{"error":"bad_refresh_token"}"#.utf8))
        }
        let service = ProjectAccessOAuthService(
            clientID: "client",
            session: URLProtocolStub.ephemeralSession(),
            oauthBaseURL: oauthURL
        )

        await #expect(throws: ProjectAccessOAuthError.badRefreshToken) {
            try await service.refreshCredential(using: "expired")
        }
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

/// URLSession 可能把 `httpBody` 内部化为 `httpBodyStream`；在 URLProtocol handler
/// 收到请求时读取，避免测试把 Foundation 的存储细节误判为业务没有发送 JSON。
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
