//
//  GoogleTranslationClientTests.swift
//  StarcatTests
//
//  覆盖 Google 翻译的 Cloud Key 路径、无 Key 公开路径和 HTTP 错误归一化。
//  所有请求都由 URLProtocolStub 拦截，不访问真实 Google 服务，也不会消耗额度。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GoogleTranslationClient", .serialized)
struct GoogleTranslationClientTests {

    @Test("有 API Key 时发送 Cloud Translation 批量请求")
    func cloudRouteSendsAPIKeyAndBatch() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }

        URLProtocolStub.requestHandler = { request in
            guard let url = request.url, let body = request.httpBody else {
                throw URLError(.badServerResponse)
            }
            #expect(request.httpMethod == "POST")
            #expect(url.query?.contains("key=test-key") == true)

            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            #expect(object["q"] as? [String] == ["Hello", "World"])
            #expect(object["target"] as? String == "zh-CN")

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data("{\"data\":{\"translations\":[{\"translatedText\":\"你好\"},{\"translatedText\":\"世界\"}]}}".utf8)
            return (response, data)
        }

        let client = GoogleTranslationClient(
            apiKey: "test-key",
            session: URLProtocolStub.ephemeralSession()
        )
        let translations = try await client.translate(
            texts: ["Hello", "World"],
            targetLanguage: .simplifiedChinese
        )

        #expect(client.route == .cloud)
        #expect(translations == ["你好", "世界"])
    }

    @Test("无 API Key 时使用公开接口并自动检测源语言")
    func publicRouteUsesWebEndpoint() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }

        URLProtocolStub.requestHandler = { request in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let query = components.queryItems else {
                throw URLError(.badServerResponse)
            }
            #expect(request.httpMethod == "GET")
            #expect(query.first(where: { $0.name == "client" })?.value == "gtx")
            #expect(query.first(where: { $0.name == "sl" })?.value == "auto")
            #expect(query.first(where: { $0.name == "tl" })?.value == "zh-CN")

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let payload: [Any] = [
                [[
                    "你好",
                    "Hello",
                    NSNull(),
                    NSNull(),
                    1
                ]],
                NSNull(),
                "en",
                NSNull()
            ]
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }

        let client = GoogleTranslationClient(
            apiKey: nil,
            session: URLProtocolStub.ephemeralSession()
        )
        let translations = try await client.translate(
            texts: ["Hello"],
            targetLanguage: .simplifiedChinese
        )

        #expect(client.route == .publicWeb)
        #expect(translations == ["你好"])
    }

    @Test("429 被归一化为限流错误")
    func rateLimitIsStableError() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badServerResponse) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = GoogleTranslationClient(
            apiKey: nil,
            session: URLProtocolStub.ephemeralSession()
        )
        await #expect(throws: GoogleTranslationError.rateLimited) {
            _ = try await client.translate(texts: ["Hello"], targetLanguage: .simplifiedChinese)
        }
    }
}
