//
//  RepositoryDecisionServiceTests.swift
//  StarcatTests
//
//  覆盖 Labs POC 的 TypeSafe(Jev)链路:
//  - TypeSafeClient 的 wire contract(请求体 / 鉴权 / 错误映射 / 429 重试);
//  - RepositoryDecisionService 的 Noul 扇出 → 建议映射(阈值过滤 / 避重 / 封闭集校验);
//  - 两个路由器的分流矩阵（分组与标签均覆盖手动 / 自动入口，并按配置回退 LLM）。
//
//  所有网络均由 URLProtocolStub 拦截,不依赖 api.typesafe.ai 实时状态。
//

import Testing
import Foundation
@testable import Starcat

// MARK: - Client wire contract

@Suite("TypeSafeClient", .serialized)
struct TypeSafeClientTests {
    private let baseURL = URL(string: "https://typesafe.test.invalid")!
    private let openRouterBaseURL = URL(string: "https://openrouter.test.invalid")!

    private func makeClient() -> TypeSafeClient {
        URLProtocolStub.reset()
        return TypeSafeClient(
            baseURL: baseURL,
            openRouterBaseURL: openRouterBaseURL,
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private func response(
        for request: URLRequest,
        status: Int,
        body: String,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }

    private let successBody = """
    {
      "model": "jev-1.13.0",
      "answers": {
        "q1": { "type": "noul", "noul": 0.87 },
        "q2": { "type": "choice", "choice": "b", "probabilities": { "a": 0.2, "b": 0.8 }, "confidence": 0.9 }
      },
      "usage": { "input_tokens": 312, "output_tokens": 48 }
    }
    """

    @Test("请求体携带 state/model/questions 与 Bearer Key")
    func requestContract() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        struct State: Encodable { let name: String }
        _ = try await client.evaluate(
            state: State(name: "starcat"),
            model: "jev-1.13.0",
            questions: [
                "q1": .noul(instructions: "Is it software?", criteria: TypeSafeNoulCriteria(true: "yes", false: "no"))
            ],
            apiKey: "tsk-test"
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.absoluteString == "https://typesafe.test.invalid/v1/systemone")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tsk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let bodyObject = try #require(body)
        #expect((bodyObject["state"] as? [String: Any])?["name"] as? String == "starcat")
        #expect(bodyObject["model"] as? String == "jev-1.13.0")
        let questions = try #require(bodyObject["questions"] as? [String: Any])
        let q1 = try #require(questions["q1"] as? [String: Any])
        #expect(q1["type"] as? String == "noul")
        #expect(q1["instructions"] as? String == "Is it software?")
        let criteria = try #require(q1["criteria"] as? [String: Any])
        #expect(criteria["true"] as? String == "yes")
        #expect(criteria["false"] as? String == "no")
    }

    @Test("模型列表使用原生 GET 端点和 Bearer Key，按 name 解码")
    func modelListContract() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: """
            {"models":[
              {"name":"jev-latest","description":"stable","release_date":"2026-10-01"},
              {"name":"jev-preview"}
            ]}
            """)
        }
        let models = try await client.listModels(apiKey: " native-test ")
        #expect(models == ["jev-latest", "jev-preview"])
        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.absoluteString == "https://typesafe.test.invalid/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer native-test")
    }

    @Test("模型列表拒绝空 Key，未发出请求")
    func modelListRejectsMissingKey() async {
        let client = makeClient()
        await #expect(throws: TypeSafeClientError.missingAPIKey) {
            _ = try await client.listModels(apiKey: " \n ")
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("模型列表认证失败保持领域错误")
    func modelListRejectsInvalidKey() async {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 401, body: "{}")
        }
        await #expect(throws: TypeSafeClientError.unauthorized) {
            _ = try await client.listModels(apiKey: "invalid-test")
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("模型列表结构错误不能伪装为空列表成功")
    func modelListRejectsMalformedResponse() async {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: #"{"models":[{"id":"missing-name"}]}"#)
        }
        do {
            _ = try await client.listModels(apiKey: "test")
            Issue.record("Expected decoding failure")
        } catch {
            guard let clientError = error as? TypeSafeClientError, case .decoding = clientError else {
                Issue.record("Expected TypeSafeClientError.decoding, got \(error)")
                return
            }
        }
    }

    @Test("OpenRouter fallback 使用 Decisions 路径与独立 Jev 模型命名空间")
    func openRouterDecisionContract() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        _ = try await client.evaluate(
            state: "demo",
            model: JevDecisionEngine.openRouterModelID,
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "sk-or-test",
            api: .openRouter
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.absoluteString == "https://openrouter.test.invalid/api/alpha/decisions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "typesafe/jev-1.13")
    }

    @Test("无 criteria 的 Noul 问题不编码 criteria 键")
    func noulCriteriaOptional() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        _ = try await client.evaluate(
            state: "demo",
            model: "jev-1.13.0",
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "tsk-test"
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let questions = try #require(body?["questions"] as? [String: Any])
        let q1 = try #require(questions["q1"] as? [String: Any])
        #expect(q1["criteria"] == nil)
    }

    @Test("空 API Key 直接抛 missingAPIKey,不发网络请求")
    func emptyKeyRejected() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }
        await #expect(throws: TypeSafeClientError.missingAPIKey) {
            _ = try await client.evaluate(
                state: "demo",
                model: "jev-1.13.0",
                questions: [:],
                apiKey: "   "
            )
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("响应解码 Noul 概率 / Choice 分布 / usage")
    func responseDecoding() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        let response = try await client.evaluate(
            state: "demo",
            model: "jev-1.13.0",
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "tsk-test"
        )

        #expect(response.answers["q1"]?.noul == 0.87)
        #expect(response.answers["q2"]?.probabilities?["b"] == 0.8)
        #expect(response.usage?.inputTokens == 312)
    }

    @Test("401 映射为 unauthorized")
    func unauthorizedMapping() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 401, body: #"{"error":"invalid key"}"#)
        }
        await #expect(throws: TypeSafeClientError.unauthorized) {
            _ = try await client.evaluate(
                state: "demo", model: "jev-1.13.0", questions: [:], apiKey: "tsk-test"
            )
        }
    }

    @Test("429 后按退避重试,恢复后成功")
    func retriesAfterRateLimit() async throws {
        let client = makeClient()
        let counter = RequestCounter()
        URLProtocolStub.requestHandler = { request in
            counter.increment()
            if counter.value <= 1 {
                return self.response(for: request, status: 429, body: "{}")
            }
            return self.response(for: request, status: 200, body: self.successBody)
        }

        let response = try await client.evaluate(
            state: "demo",
            model: "jev-1.13.0",
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "tsk-test"
        )
        #expect(response.answers["q1"]?.noul == 0.87)
        #expect(URLProtocolStub.receivedRequests.count == 2)
    }

    @Test("500 与瞬时传输错误在客户端层有限重试")
    func retriesServerAndTransportFailures() async throws {
        for failure in ["server", "transport"] {
            let client = makeClient()
            let counter = RequestCounter()
            URLProtocolStub.requestHandler = { request in
                counter.increment()
                if counter.value == 1 {
                    if failure == "transport" { throw URLError(.networkConnectionLost) }
                    return self.response(for: request, status: 500, body: "{}")
                }
                return self.response(for: request, status: 200, body: self.successBody)
            }

            let response = try await client.evaluate(
                state: "demo",
                model: "jev-1.13.0",
                questions: ["q1": .noul(instructions: "demo", criteria: nil)],
                apiKey: "tsk-test"
            )
            #expect(response.answers["q1"]?.noul == 0.87)
            #expect(URLProtocolStub.receivedRequests.count == 2)
        }
    }

    @Test("422 属于永久请求错误且不重试")
    func validationDoesNotRetry() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 422, body: #"{"detail":"bad state"}"#)
        }

        await #expect(throws: TypeSafeClientError.validation("bad state")) {
            _ = try await client.evaluate(
                state: "demo",
                model: "jev-1.13.0",
                questions: ["q1": .noul(instructions: "demo", criteria: nil)],
                apiKey: "tsk-test"
            )
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }
}

/// URLProtocol 的 handler 闭包是 @Sendable,用锁计数器跨隔离记录次数。
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

// MARK: - Service 映射

@MainActor
@Suite("RepositoryDecisionService", .serialized)
struct RepositoryDecisionServiceTests {

    private var defaults: UserDefaults {
        let suite = UserDefaults(suiteName: "RepositoryDecisionServiceTests")!
        suite.removePersistentDomain(forName: "RepositoryDecisionServiceTests")
        return suite
    }

    private func makeService(
        settings: AppSettings,
        keychain: InMemoryKeychain
    ) throws -> RepositoryDecisionService {
        URLProtocolStub.reset()
        let database = try InMemoryDatabaseManager()
        return RepositoryDecisionService(
            client: TypeSafeClient(
                baseURL: URL(string: "https://typesafe.test.invalid")!,
                openRouterBaseURL: URL(string: "https://openrouter.test.invalid")!,
                session: URLProtocolStub.ephemeralSession()
            ),
            settings: settings,
            readmeRepository: ReadmeRepository(database: database),
            keychain: keychain
        )
    }

    private func storeKey(_ key: InMemoryKeychain) throws {
        try key.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
    }

    private func stubAnswers(_ json: String) {
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    private func lastRequestBody() throws -> [String: Any] {
        let request = try #require(URLProtocolStub.receivedRequests.last)
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func questionKeysOfLastRequest() throws -> [String] {
        let body = try lastRequestBody()
        return Array((body["questions"] as? [String: Any])?.keys ?? [:].keys)
    }

    private func makeCandidate(id: String, name: String, instruction: String) -> GitHubStarListAIContext {
        GitHubStarListAIContext(listId: id, name: name, instruction: instruction, autoApplyEnabled: false)
    }

    private func makeOpenRouterProfile(
        isEnabled: Bool = true,
        status: AIProviderTestStatus = .success(modelCount: 1)
    ) -> AIProviderProfile {
        AIProviderProfile(
            id: "openrouter-primary",
            provider: .openRouter,
            displayName: "OpenRouter Primary",
            isEnabled: isEnabled,
            lastTestStatus: status
        )
    }

    // MARK: 分组

    @Test("分组:保留完整概率并使用结构化规则,产出经封闭集校验")
    func groupingMapsProbabilities() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "list::ml": { "type": "noul", "noul": 0.9 },
            "list::web": { "type": "noul", "noul": 0.4 }
          },
          "usage": { "input_tokens": 100, "output_tokens": 2 }
        }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [
                makeCandidate(id: "ml", name: "ML", instruction: "machine learning tools"),
                makeCandidate(id: "web", name: "Web", instruction: "frontend projects")
            ],
            existingListIDsByRepo: [1: []],
            existingListNamesByRepo: [1: []]
        )

        let suggestions = try #require(results[1])
        #expect(suggestions.count == 2)
        #expect(suggestions[0].listId == "ml")
        #expect(abs(suggestions[0].confidence - 0.9) < 0.0001)
        #expect(suggestions[0].reason.hasPrefix("Jev P="))
        #expect(suggestions[1].listId == "web")
        #expect(abs(suggestions[1].confidence - 0.4) < 0.0001)

        let body = try lastRequestBody()
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["repository"] != nil)
        #expect(state["readmeExcerpt"] != nil)
        #expect(state["existingListNames"] != nil)
        let questions = try #require(body["questions"] as? [String: Any])
        let question = try #require(questions["list::ml"] as? [String: Any])
        let instructions = try #require(question["instructions"] as? [String: String])
        #expect(instructions["main_question"]?.contains("`repository`") == true)
        #expect(instructions["main_question"]?.contains("`readmeExcerpt`") == true)
        #expect(instructions["existing_memberships_note"]?.contains("`existingListNames`") == true)
        #expect(instructions["list_name"] == "ML")
        #expect(instructions["list_rule"] == "machine learning tools")
        let criteria = try #require(question["criteria"] as? [String: String])
        #expect(criteria["true"] == "The repository clearly satisfies `list_rule`.")
        #expect(criteria["false"] == "The repository does not satisfy `list_rule`.")
    }

    @Test("分组:已有 membership 的 List 不进入问题集")
    func groupingSkipsExistingMemberships() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        { "model": "jev-1.13.0", "answers": { "list::web": { "type": "noul", "noul": 0.9 } } }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        _ = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [
                makeCandidate(id: "ml", name: "ML", instruction: "machine learning tools"),
                makeCandidate(id: "web", name: "Web", instruction: "frontend projects")
            ],
            existingListIDsByRepo: [1: ["ml"]],
            existingListNamesByRepo: [1: ["ML"]]
        )

        let keys = try questionKeysOfLastRequest()
        #expect(keys == ["list::web"])
    }

    @Test("分组:空 instruction 的 List 不是候选")
    func groupingIgnoresEmptyInstruction() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        // 全部候选 instruction 为空:直接返回空结果,不发网络请求。
        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [makeCandidate(id: "ml", name: "ML", instruction: "  ")],
            existingListIDsByRepo: [1: []],
            existingListNamesByRepo: [1: []]
        )
        #expect(results.isEmpty)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("分组:完整低概率响应保留给产品策略判断")
    func groupingPreservesCompleteLowProbabilityResponse() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)
        stubAnswers(#"{"model":"jev-1.13.0","answers":{"list::ml":{"type":"noul","noul":0.2}}}"#)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [makeCandidate(id: "ml", name: "ML", instruction: "machine learning tools")],
            existingListIDsByRepo: [1: []],
            existingListNamesByRepo: [1: []]
        )

        #expect(results[1]?.map(\.confidence) == [0.2])
    }

    @Test("分组:Service 不截断五个之后的完整概率")
    func groupingPreservesMoreThanFiveProbabilities() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)
        stubAnswers("""
        {
          "answers": {
            "list::l1": { "type": "noul", "noul": 0.91 },
            "list::l2": { "type": "noul", "noul": 0.82 },
            "list::l3": { "type": "noul", "noul": 0.73 },
            "list::l4": { "type": "noul", "noul": 0.64 },
            "list::l5": { "type": "noul", "noul": 0.55 },
            "list::l6": { "type": "noul", "noul": 0.46 }
          }
        }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let candidates = (1...6).map { index in
            makeCandidate(id: "l\(index)", name: "L\(index)", instruction: "rule \(index)")
        }
        let results = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: candidates,
            existingListIDsByRepo: [1: []],
            existingListNamesByRepo: [1: []]
        )

        #expect(results[1]?.map(\.listId) == ["l1", "l2", "l3", "l4", "l5", "l6"])
    }

    @Test("分组:缺失必答键不能伪装成无匹配")
    func groupingRejectsMissingAnswer() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)
        stubAnswers(#"{"model":"jev-1.13.0","answers":{}}"#)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        await #expect(throws: TypeSafeClientError.invalidAnswer(questionID: "list::ml")) {
            _ = try await service.generateGitHubListSuggestions(
                for: [repo],
                candidates: [makeCandidate(id: "ml", name: "ML", instruction: "machine learning tools")],
                existingListIDsByRepo: [1: []],
                existingListNamesByRepo: [1: []]
            )
        }
    }

    // MARK: 标签

    @Test("标签:按概率生成建议并截断到数量上限")
    func tagsMapAndCap() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "tag::ai": { "type": "noul", "noul": 0.9 },
            "tag::cli": { "type": "noul", "noul": 0.8 },
            "tag::unrelated": { "type": "noul", "noul": 0.3 },
            "tag::swift": { "type": "noul", "noul": 0.7 }
          },
          "usage": { "input_tokens": 100, "output_tokens": 4 }
        }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [
                1: AITagHints(repoTags: [], libraryTags: ["ai", "cli", "unrelated", "swift"])
            ]
        )

        let suggestions = try #require(results[1])
        // 默认上限 3:ai(0.9)/cli(0.8)/swift(0.7) 入选;unrelated(0.3) 低于 0.5 下限被过滤。
        #expect(suggestions.map(\.name) == ["ai", "cli", "swift"])
        #expect(suggestions.map(\.confidence) == [0.9, 0.8, 0.7])
        #expect(suggestions.allSatisfy { $0.engine == .jev })

        let body = try lastRequestBody()
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["readmeExcerpt"] != nil)
        #expect(state["existingTags"] != nil)
        #expect(state["existing_tags"] == nil)
        let questions = try #require(body["questions"] as? [String: Any])
        let question = try #require(questions["tag::ai"] as? [String: Any])
        let instructions = try #require(question["instructions"] as? String)
        #expect(instructions.contains("`readmeExcerpt`"))
        #expect(instructions.contains("`existingTags`"))
        #expect(!instructions.contains("existing_tags"))
    }

    @Test("标签:答案类型或概率范围无效时整仓失败")
    func tagsRejectInvalidNoulAnswer() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)
        stubAnswers(
            #"{"model":"jev-1.13.0","answers":{"tag::ai":{"type":"choice","noul":1.2}}}"#
        )

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        await #expect(throws: TypeSafeClientError.invalidAnswer(questionID: "tag::ai")) {
            _ = try await service.generateBatchTagSuggestions(
                for: [repo],
                tagHintsByRepoID: [1: AITagHints(repoTags: [], libraryTags: ["ai"])]
            )
        }
    }

    @Test("标签:repo 已有标签不再进入问题集")
    func tagsExcludeRepoOwnTags() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        { "model": "jev-1.13.0", "answers": { "tag::cli": { "type": "noul", "noul": 0.9 } } }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        _ = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [
                1: AITagHints(repoTags: ["AI"], libraryTags: ["ai", "cli"])
            ]
        )

        // "AI" 与 "ai" 是同一 canonical key,视为 repo 已有,不再询问。
        #expect(try questionKeysOfLastRequest() == ["tag::cli"])
    }

    @Test("标签:词表为空时返回空建议且不发请求")
    func tagsEmptyVocabulary() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [1: .empty]
        )
        #expect(results[1] == [])
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("原生 Key 缺失时复用已验证 OpenRouter Key 调用 Decisions API")
    func openRouterFallbackActivatesWhenNativeKeyIsMissing() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let profile = makeOpenRouterProfile()
        settings.aiProviderProfiles = [profile]
        try keychain.storeAIKey("sk-or-test", forProvider: profile.id)
        let service = try makeService(settings: settings, keychain: keychain)
        stubAnswers(
            #"{"model":"typesafe/jev-1.13","answers":{"tag::swift":{"type":"noul","noul":0.9}}}"#
        )

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [1: AITagHints(repoTags: [], libraryTags: ["swift"])]
        )

        #expect(results[1]?.map(\.name) == ["swift"])
        let request = try #require(URLProtocolStub.receivedRequests.last)
        #expect(request.url?.absoluteString == "https://openrouter.test.invalid/api/alpha/decisions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(try lastRequestBody()["model"] as? String == JevDecisionEngine.openRouterModelID)
    }

    @Test("原生 TypeSafe Key 始终优先于 OpenRouter fallback")
    func nativeKeyTakesPrecedenceOverOpenRouter() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let profile = makeOpenRouterProfile()
        settings.aiProviderProfiles = [profile]
        try keychain.storeAIKey("sk-or-test", forProvider: profile.id)
        try keychain.storeServiceAPIKey(
            "tsk-native",
            forService: JevDecisionEngine.keychainServiceID
        )
        let service = try makeService(settings: settings, keychain: keychain)
        stubAnswers(
            #"{"model":"jev-1.13.0","answers":{"tag::swift":{"type":"noul","noul":0.9}}}"#
        )

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        _ = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [1: AITagHints(repoTags: [], libraryTags: ["swift"])]
        )

        let request = try #require(URLProtocolStub.receivedRequests.last)
        #expect(request.url?.absoluteString == "https://typesafe.test.invalid/v1/systemone")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tsk-native")
        #expect(try lastRequestBody()["model"] as? String == JevDecisionEngine.defaultModelID)
    }

    @Test("原生 Key 最近测试失败时保留 Key 但改走 OpenRouter")
    func nativeTestFailureActivatesOpenRouterFallback() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let profile = makeOpenRouterProfile()
        settings.aiProviderProfiles = [profile]
        settings.typesafeNativeKeyTestFailed = true
        try keychain.storeAIKey("sk-or-test", forProvider: profile.id)
        try keychain.storeServiceAPIKey(
            "tsk-native",
            forService: JevDecisionEngine.keychainServiceID
        )
        let service = try makeService(settings: settings, keychain: keychain)
        stubAnswers(
            #"{"model":"typesafe/jev-1.13","answers":{"tag::swift":{"type":"noul","noul":0.9}}}"#
        )

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        _ = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [1: AITagHints(repoTags: [], libraryTags: ["swift"])]
        )

        let request = try #require(URLProtocolStub.receivedRequests.last)
        #expect(request.url?.absoluteString == "https://openrouter.test.invalid/api/alpha/decisions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-test")
        #expect(try lastRequestBody()["model"] as? String == JevDecisionEngine.openRouterModelID)
    }

    @Test("显式原生 Key override 可绕过失败标记执行重测")
    func nativeOverrideCanRetryAfterFailure() throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let profile = makeOpenRouterProfile()
        settings.aiProviderProfiles = [profile]
        settings.typesafeNativeKeyTestFailed = true
        try keychain.storeAIKey("sk-or-test", forProvider: profile.id)
        try keychain.storeServiceAPIKey(
            "tsk-stored",
            forService: JevDecisionEngine.keychainServiceID
        )

        let access = try #require(
            JevDecisionEngine.resolveAccess(
                settings: settings,
                keychain: keychain,
                nativeAPIKeyOverride: "tsk-retry"
            )
        )

        #expect(access.source == .typeSafe)
        #expect(access.apiKey == "tsk-retry")
        #expect(access.modelID == JevDecisionEngine.defaultModelID)
    }

    @Test("原生 Key 测试失败且 OpenRouter 不可用时 Jev 凭据不可解析")
    func failedNativeKeyWithoutOpenRouterIsUnavailable() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.typesafeNativeKeyTestFailed = true
        try keychain.storeServiceAPIKey(
            "tsk-native",
            forService: JevDecisionEngine.keychainServiceID
        )
        let service = try makeService(settings: settings, keychain: keychain)

        #expect(!service.isSelectedEngineAvailable)
    }

    @Test("未验证、已停用或缺 Key 的 OpenRouter profile 不启用 fallback")
    func unusableOpenRouterProfilesDoNotActivateFallback() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)

        let unverified = makeOpenRouterProfile(status: .notTested)
        settings.aiProviderProfiles = [unverified]
        try keychain.storeAIKey("sk-or-test", forProvider: unverified.id)
        #expect(!service.isSelectedEngineAvailable)

        settings.aiProviderProfiles = [makeOpenRouterProfile(isEnabled: false)]
        #expect(!service.isSelectedEngineAvailable)

        try keychain.deleteAIKey(forProvider: unverified.id)
        settings.aiProviderProfiles = [makeOpenRouterProfile()]
        #expect(!service.isSelectedEngineAvailable)
    }

    @Test("Key 未配置时所选引擎不可用")
    func keyResolution() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        #expect(!service.isSelectedEngineAvailable)
        try storeKey(keychain)
        #expect(service.isSelectedEngineAvailable)
    }
}

// MARK: - 路由矩阵

@MainActor
@Suite("DecisionSuggestionRouters", .serialized)
struct DecisionSuggestionRoutersTests {

    private final class RecordingListProvider: GitHubStarListSuggestionProviding {
        private(set) var callCount = 0
        func generateGitHubListSuggestions(
            for repos: [Repo],
            candidates: [GitHubStarListAIContext],
            existingListIDsByRepo: [Int64: Set<String>],
            existingListNamesByRepo: [Int64: [String]]
        ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
            callCount += 1
            return [:]
        }
    }

    /// 路由器及其 fallback 都固定在 MainActor；测试桩遵循同一隔离边界，避免把可变记录状态
    /// 发送到并发执行器后再由测试读取。
    @MainActor
    private final class RecordingTagFallback {
        private(set) var callCount = 0
        private(set) var tagPurposes: [AITagSuggestionPurpose] = []
        var tagSuggestions: [AITagSuggestion] = []

        func generate(
            for repos: [Repo],
            tagHintsByRepoID: [Int64: AITagHints],
            purpose: AITagSuggestionPurpose
        ) async throws -> [Int64: [AITagSuggestion]] {
            callCount += 1
            tagPurposes.append(purpose)
            return Dictionary(uniqueKeysWithValues: repos.map { ($0.id, tagSuggestions) })
        }
    }

    private func makeSettings(
        keychain: InMemoryKeychain,
        enabled: Bool,
        grouping: Bool,
        tags: Bool
    ) -> AppSettings {
        let suite = UserDefaults(suiteName: "DecisionSuggestionRoutersTests")!
        suite.removePersistentDomain(forName: "DecisionSuggestionRoutersTests")
        let settings = AppSettings(defaults: suite, keychain: keychain)
        settings.decisionEngineEnabled = enabled
        settings.decisionGroupingSuggestionsEnabled = grouping
        settings.decisionTagSuggestionsEnabled = tags
        return settings
    }

    private func makeJevStubService(
        settings: AppSettings,
        keychain: InMemoryKeychain,
        noulProbability: Double = 0.1
    ) throws -> RepositoryDecisionService {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let requestBody = try #require(request.httpBody)
            let object = try #require(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let questions = try #require(object["questions"] as? [String: Any])
            let answers = Dictionary(uniqueKeysWithValues: questions.keys.map { questionID in
                (questionID, ["type": "noul", "noul": noulProbability] as [String: Any])
            })
            let body = try JSONSerialization.data(withJSONObject: [
                "model": "jev-1.13.0",
                "answers": answers
            ])
            return (response, body)
        }
        let database = try InMemoryDatabaseManager()
        return RepositoryDecisionService(
            client: TypeSafeClient(
                baseURL: URL(string: "https://typesafe.test.invalid")!,
                openRouterBaseURL: URL(string: "https://openrouter.test.invalid")!,
                session: URLProtocolStub.ephemeralSession()
            ),
            settings: settings,
            readmeRepository: ReadmeRepository(database: database),
            keychain: keychain
        )
    }

    private var sampleRepos: [Repo] {
        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        return [repo]
    }

    // MARK: 分组路由

    @Test("总开关开 + 有 Key → 手动分组走 Jev")
    func groupingRoutesToTypesafeWhenEnabled() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let llm = RecordingListProvider()
        let router = DecisionGitHubListSuggestionRouter(
            llmProvider: llm,
            decisionProvider: try makeJevStubService(settings: settings, keychain: keychain),
            settings: settings
        )

        _ = try await router.generateGitHubListSuggestions(
            for: sampleRepos,
            candidates: [
                GitHubStarListAIContext(
                    listId: "ml", name: "ML", instruction: "machine learning tools", autoApplyEnabled: false
                )
            ],
            existingListIDsByRepo: [:],
            existingListNamesByRepo: [:]
        )
        #expect(llm.callCount == 0)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("共享路由不再限制手动上下文 → 自动分组也走 Jev")
    func groupingRoutesToTypesafeWhenAutomatic() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let llm = RecordingListProvider()
        let router = DecisionGitHubListSuggestionRouter(
            llmProvider: llm,
            decisionProvider: try makeJevStubService(settings: settings, keychain: keychain),
            settings: settings
        )

        _ = try await router.generateGitHubListSuggestions(
            for: sampleRepos,
            candidates: [
                GitHubStarListAIContext(
                    listId: "ml", name: "ML", instruction: "machine learning tools", autoApplyEnabled: true
                )
            ],
            existingListIDsByRepo: [:],
            existingListNamesByRepo: [:]
        )
        #expect(llm.callCount == 0)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("总开关关 / Key 缺失 → 分组走 LLM")
    func groupingFallsBackWhenDisabledOrKeyless() async throws {
        // 关:开关关但 Key 在
        do {
            let keychain = InMemoryKeychain()
            try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
            let settings = makeSettings(keychain: keychain, enabled: false, grouping: true, tags: true)
            let llm = RecordingListProvider()
            let router = DecisionGitHubListSuggestionRouter(
                llmProvider: llm,
                decisionProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings
            )
            _ = try await router.generateGitHubListSuggestions(
                for: sampleRepos, candidates: [], existingListIDsByRepo: [:], existingListNamesByRepo: [:]
            )
            #expect(llm.callCount == 1)
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }

        // 无 Key:开关开但没有 Key
        do {
            let keychain = InMemoryKeychain()
            let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
            let llm = RecordingListProvider()
            let router = DecisionGitHubListSuggestionRouter(
                llmProvider: llm,
                decisionProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings
            )
            _ = try await router.generateGitHubListSuggestions(
                for: sampleRepos, candidates: [], existingListIDsByRepo: [:], existingListNamesByRepo: [:]
            )
            #expect(llm.callCount == 1)
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }
    }

    // MARK: 标签路由

    @Test("Jev 开启时空词表直接调用 newOnly；关闭或缺 Key 时保持普通 LLM")
    func tagRoutingMatrix() async throws {
        do {
            let keychain = InMemoryKeychain()
            try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
            let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
            let fallback = RecordingTagFallback()
            let router = DecisionTagSuggestionRouter(
                decisionProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings
            )
            _ = try await router.generateTagSuggestions(
                for: sampleRepos,
                tagHintsByRepoID: [1: .empty],
                policy: .manualReview
            ) { repos, hints, purpose in
                try await fallback.generate(for: repos, tagHintsByRepoID: hints, purpose: purpose)
            }
            #expect(fallback.callCount == 1)
            #expect(fallback.tagPurposes == [.newOnly])
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }

        for hasKey in [true, false] {
            let keychain = InMemoryKeychain()
            if hasKey {
                try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
            }
            let settings = makeSettings(
                keychain: keychain,
                enabled: !hasKey,
                grouping: false,
                tags: !hasKey
            )
            let fallback = RecordingTagFallback()
            let router = DecisionTagSuggestionRouter(
                decisionProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings
            )
            _ = try await router.generateTagSuggestions(
                for: sampleRepos,
                tagHintsByRepoID: [1: .empty],
                policy: .manualReview
            ) { repos, hints, purpose in
                try await fallback.generate(for: repos, tagHintsByRepoID: hints, purpose: purpose)
            }
            #expect(fallback.tagPurposes == [.reuseFirst])
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }
    }

    @Test("Jev 结果满足数量和置信度时不调用 LLM")
    func tagsSkipLLMWhenJevIsSufficient() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let fallback = RecordingTagFallback()
        let router = DecisionTagSuggestionRouter(
            decisionProvider: try makeJevStubService(
                settings: settings,
                keychain: keychain,
                noulProbability: 0.92
            ),
            settings: settings
        )

        let results = try await router.generateTagSuggestions(
            for: sampleRepos,
            tagHintsByRepoID: [1: AITagHints(repoTags: [], libraryTags: ["Swift"])],
            policy: AITagGenerationPolicy(allowNewTags: true, minimumReusableConfidence: 0.90)
        ) { repos, hints, purpose in
            try await fallback.generate(for: repos, tagHintsByRepoID: hints, purpose: purpose)
        }

        #expect(results[1]?.map(\.name) == ["Swift"])
        #expect(fallback.callCount == 0)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("单仓标签生成经统一路由走 Jev，且不要求无关的 LLM 配置")
    func singleRepoInsightUsesUnifiedTagRouter() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let router = DecisionTagSuggestionRouter(
            decisionProvider: try makeJevStubService(
                settings: settings,
                keychain: keychain,
                noulProbability: 0.94
            ),
            settings: settings
        )
        let database = try InMemoryDatabaseManager()
        let service = RepoAIInsightService(
            summaryRepository: GRDBAISummaryRepository(database: database),
            readmeRepository: ReadmeRepository(database: database),
            settings: settings,
            keychain: keychain,
            tagSuggestionRouter: router
        )
        let repo = try #require(sampleRepos.first)

        let result = try await service.generateInsight(
            for: repo,
            existingTagHints: AITagHints(repoTags: [], libraryTags: ["Swift"]),
            includeSummary: false,
            includeTags: true
        )

        #expect(result.insight.suggestedTags.map(\.name) == ["Swift"])
        #expect(result.tagErrorMessage == nil)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("Jev 结果不足时仅生成新标签并合并，且不二次验证新标签")
    func tagsFallbackToNewOnlyAndMerge() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        settings.applyAITagSuggestionCounts(minimum: 2, maximum: 3)
        let fallback = RecordingTagFallback()
        fallback.tagSuggestions = [
            AITagSuggestion(
                name: "Rust",
                confidence: 0.83,
                reason: "new systems language",
                engine: .llm
            ),
            AITagSuggestion(
                name: "swift",
                confidence: 0.99,
                reason: "must be rejected",
                engine: .llm
            )
        ]
        let router = DecisionTagSuggestionRouter(
            decisionProvider: try makeJevStubService(
                settings: settings,
                keychain: keychain,
                noulProbability: 0.91
            ),
            settings: settings
        )

        let results = try await router.generateTagSuggestions(
            for: sampleRepos,
            tagHintsByRepoID: [
                1: AITagHints(repoTags: [], libraryTags: ["Swift", "CLI", "AI"])
            ],
            policy: AITagGenerationPolicy(allowNewTags: true, minimumReusableConfidence: 0.95)
        ) { repos, hints, purpose in
            try await fallback.generate(for: repos, tagHintsByRepoID: hints, purpose: purpose)
        }

        #expect(results[1]?.count == 3)
        #expect(results[1]?.contains(where: { $0.name == "Rust" }) == true)
        #expect(results[1]?.first(where: { $0.name == "Rust" })?.engine == .llm)
        #expect(results[1]?.filter { $0.name != "Rust" }.allSatisfy { $0.engine == .jev } == true)
        #expect(fallback.callCount == 1)
        #expect(fallback.tagPurposes == [.newOnly])
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("禁止新增时 Jev 不足也不调用 LLM")
    func tagsDoNotFallbackWhenNewTagsAreDisabled() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: JevDecisionEngine.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let fallback = RecordingTagFallback()
        let router = DecisionTagSuggestionRouter(
            decisionProvider: try makeJevStubService(
                settings: settings,
                keychain: keychain,
                noulProbability: 0.6
            ),
            settings: settings
        )

        let results = try await router.generateTagSuggestions(
            for: sampleRepos,
            tagHintsByRepoID: [1: AITagHints(repoTags: [], libraryTags: ["Swift"])],
            policy: AITagGenerationPolicy(allowNewTags: false, minimumReusableConfidence: 0.9)
        ) { repos, hints, purpose in
            try await fallback.generate(for: repos, tagHintsByRepoID: hints, purpose: purpose)
        }

        #expect(results[1]?.map(\.name) == ["Swift"])
        #expect(fallback.callCount == 0)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }
}
