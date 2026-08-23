//
//  RecommendAPILiveIntegrationTests.swift
//  StarcatTests
//
//  Starcat RecommendAPI → 本机 starcat-recommend-api v2 的显式 live E2E 入口。
//
//  常规测试不访问网络；只有同时提供 BASE_URL 和 API_KEY 环境变量时才执行。
//  这条测试复用产品 actor 和 v2 DTO，证明真实 ServingBundle 可被 Direct 客户端解码，
//  不以 curl 成功替代客户端契约验收。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Recommend API Live Integration")
struct RecommendAPILiveIntegrationTests {
    @Test("Direct v2 客户端应读取本机已激活 ServingBundle")
    func fetchesActiveTrainedBundle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let liveTestRequired = environment["STARCAT_RECOMMEND_LIVE_REQUIRED"] == "1"
        guard let baseURLValue = environment["STARCAT_RECOMMEND_LIVE_BASE_URL"],
              let baseURL = URL(string: baseURLValue),
              let apiKey = environment["STARCAT_RECOMMEND_LIVE_API_KEY"],
              !apiKey.isEmpty else {
            // 全量单测必须保持离线；本机全链路验收显式提供变量后才访问服务。
            #expect(!liveTestRequired, "显式要求 live 验收时必须提供 BASE_URL 和 API_KEY")
            return
        }

        let repoID = Int64(environment["STARCAT_RECOMMEND_LIVE_REPO_ID"] ?? "") ?? 873_328
        let expectedModelVersion = environment["STARCAT_RECOMMEND_LIVE_MODEL_VERSION"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let api = RecommendAPI(
            baseURL: baseURL,
            apiKey: apiKey,
            contract: .trainedV2,
            session: URLSession(configuration: configuration)
        )

        let page = try await api.fetchRecommendations(repoID: repoID, limit: 5)

        #expect(page.source == "starcat_trained")
        #expect(page.fallback == false)
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.source == "starcat_trained" })
        if let expectedModelVersion {
            #expect(page.modelVersion == expectedModelVersion)
        } else {
            #expect(page.modelVersion?.isEmpty == false)
        }
    }
}
