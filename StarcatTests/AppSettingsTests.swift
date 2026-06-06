//
//  AppSettingsTests.swift
//  StarcatTests
//
//  验证 AppSettings 偏好持久化逻辑。
//  用 UserDefaults(suiteName:) 隔离测试，不污染共享 .standard。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {

    /// 给每个测试一个独立 suite 名，避免相互污染。
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.appsettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("默认密度为 card")
    func defaultDensity() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.listDensity == .card)
    }

    @Test("设置后从同 suite 重新读取应保留值")
    func densityPersists() {
        let defaults = makeIsolatedDefaults()

        let s1 = AppSettings(defaults: defaults)
        s1.listDensity = .compact

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.listDensity == .compact)
    }

    @Test("Pro: 默认非 Pro，设置后重新读取应保留")
    func proStatusPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        #expect(s1.isProUser == false)

        s1.isProUser = true

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.isProUser == true)
    }

    @Test("非法 raw value 回退到默认")
    func invalidValueFallsBack() {
        let defaults = makeIsolatedDefaults()
        defaults.set("invalid-density", forKey: "settings.repoListDensity")

        let s = AppSettings(defaults: defaults)
        #expect(s.listDensity == .card)
    }

    // MARK: - W4-4 D1：排序偏好

    @Test("D1: 默认排序 = starredAtDesc")
    func defaultSortIsStarredAtDesc() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        #expect(s.repoSortOption == .starredAtDesc)
    }

    @Test("D1: 设置排序后重新读取应保留")
    func sortPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.repoSortOption = .starsDesc
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.repoSortOption == .starsDesc)
    }

    @Test("D1: 非法 sortOption raw value 回退到默认")
    func sortInvalidValueFallsBack() {
        let defaults = makeIsolatedDefaults()
        defaults.set("not-a-sort", forKey: "settings.repoSortOption")
        let s = AppSettings(defaults: defaults)
        #expect(s.repoSortOption == .starredAtDesc)
    }

    // MARK: - Activity 分类偏好

    @Test("Activity: 默认分类 raw 为空，设置后重新读取应保留")
    func activityCategoryRawPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        #expect(s1.lastActivityCategoryRaw == "")

        s1.lastActivityCategoryRaw = "release"

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.lastActivityCategoryRaw == "release")
    }

    // MARK: - AI BYOK 设置

    @Test("AI: 默认使用 OpenAI-compatible + keyword 搜索")
    func aiDefaults() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        #expect(s.aiProvider == .openAICompatible)
        #expect(s.aiBaseURL == "https://api.openai.com/v1")
        #expect(s.aiChatModel == "gpt-4o-mini")
        #expect(s.aiEmbeddingModel == "text-embedding-3-small")
        #expect(s.aiProviderProfiles.count == 1)
        #expect(s.aiSummaryTask.providerID == s.aiProviderProfiles[0].id)
        #expect(s.aiTagsTask.providerID == s.aiProviderProfiles[0].id)
        #expect(s.aiEmbeddingTask.providerID == s.aiProviderProfiles[0].id)
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("{context}"))
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("## 一句话总结"))
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("## 风险与注意点"))
        #expect(s.smartSearchMode == .keyword)
    }

    @Test("AI: 旧版设置后重新读取应保留")
    func aiSettingsPersist() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.aiProvider = .ollama
        s1.aiBaseURL = "http://localhost:11434/v1"
        s1.aiChatModel = "llama3.2"
        s1.aiEmbeddingModel = "nomic-embed-text"
        s1.smartSearchMode = .semantic

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.aiProvider == .ollama)
        #expect(s2.aiBaseURL == "http://localhost:11434/v1")
        #expect(s2.aiChatModel == "llama3.2")
        #expect(s2.aiEmbeddingModel == "nomic-embed-text")
        #expect(s2.smartSearchMode == .semantic)
    }

    @Test("AI: 多服务商 profile 与任务配置应持久化")
    func aiProviderProfilesPersist() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        let remote = AIProviderProfile(
            id: "remote-openai",
            provider: .openAICompatible,
            displayName: "OpenAI Remote",
            baseURL: "https://api.openai.com/v1",
            models: [
                AIModelDescriptor(providerID: "remote-openai", name: "gpt-4o-mini", capability: .chat),
                AIModelDescriptor(providerID: "remote-openai", name: "text-embedding-3-small", capability: .embedding)
            ]
        )
        let local = AIProviderProfile(
            id: "local-lmstudio",
            provider: .lmStudio,
            displayName: "LM Studio",
            baseURL: "http://localhost:1234/v1",
            models: [
                AIModelDescriptor(providerID: "local-lmstudio", name: "qwen/qwen3.5-9b", capability: .chat)
            ]
        )
        s1.aiProviderProfiles = [remote, local]
        s1.aiSummaryTask.providerID = local.id
        s1.aiSummaryTask.modelID = "qwen/qwen3.5-9b"
        s1.aiTagsTask.providerID = remote.id
        s1.aiTagsTask.modelID = "gpt-4o-mini"
        s1.aiEmbeddingTask.providerID = remote.id
        s1.aiEmbeddingTask.modelID = "text-embedding-3-small"

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.aiProviderProfiles.map(\.id) == ["remote-openai", "local-lmstudio"])
        #expect(s2.aiSummaryTask.providerID == "local-lmstudio")
        #expect(s2.aiTagsTask.modelID == "gpt-4o-mini")
        #expect(s2.aiEmbeddingTask.modelID == "text-embedding-3-small")
    }

    // MARK: - HOM-68 follow-up v9: 模型粒度参数

    @Test("AI: AIModelParameters.defaults(for:) 按 capability 返回正确默认")
    func aiCapabilityDefaults() {
        #expect(AIModelParameters.defaults(for: .chat) == AIModelParameters.summaryDefault)
        #expect(AIModelParameters.defaults(for: .embedding) == AIModelParameters.embeddingDefault)
        // unknown 当 chat 用——大多数 OpenAI-compatible /models 接口返回 owned_by
        // 推不出能力时落到 unknown，UI 还能让用户手改成 chat / embedding。
        #expect(AIModelParameters.defaults(for: .unknown) == AIModelParameters.summaryDefault)
    }

    @Test("AI: effectiveParameters 优先用模型粒度覆盖")
    func effectiveParametersUsesModelOverride() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        var overridden = AIModelParameters.summaryDefault
        overridden.temperature = 0.77
        overridden.maxCompletionTokens = 7 * 1024

        let profile = AIProviderProfile(
            id: "p1",
            provider: .openAICompatible,
            displayName: "P1",
            baseURL: "https://example.com/v1",
            models: [
                AIModelDescriptor(
                    providerID: "p1",
                    name: "gpt-test",
                    capability: .chat,
                    parameters: overridden
                )
            ]
        )
        settings.aiProviderProfiles = [profile]
        settings.aiSummaryTask.providerID = "p1"
        settings.aiSummaryTask.modelID = "gpt-test"

        let resolved = settings.effectiveParameters(for: settings.aiSummaryTask)
        #expect(resolved.temperature == 0.77)
        #expect(resolved.maxCompletionTokens == 7 * 1024)
    }

    @Test("AI: descriptor.parameters == nil 时回退到 capability 默认")
    func effectiveParametersFallsBackToCapabilityDefault() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        let profile = AIProviderProfile(
            id: "p2",
            provider: .openAICompatible,
            displayName: "P2",
            baseURL: "https://example.com/v1",
            models: [
                AIModelDescriptor(providerID: "p2", name: "txt-embed", capability: .embedding)
                // parameters 不传 → nil
            ]
        )
        settings.aiProviderProfiles = [profile]
        settings.aiEmbeddingTask.providerID = "p2"
        settings.aiEmbeddingTask.modelID = "txt-embed"

        let resolved = settings.effectiveParameters(for: settings.aiEmbeddingTask)
        #expect(resolved == AIModelParameters.embeddingDefault)
    }

    @Test("AI: 模型不存在时回退到 task.parameters")
    func effectiveParametersFallsBackToLegacyTask() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        var legacy = AIModelParameters.summaryDefault
        legacy.temperature = 0.42
        settings.aiSummaryTask.providerID = "ghost-provider"
        settings.aiSummaryTask.modelID = "ghost-model"
        settings.aiSummaryTask.parameters = legacy

        let resolved = settings.effectiveParameters(for: settings.aiSummaryTask)
        #expect(resolved.temperature == 0.42)
    }

    @Test("AI: 老版本 descriptor JSON 缺少 parameters 字段时解码为 nil")
    func descriptorParametersDecodesOptional() throws {
        // 模拟老版本（v8 之前）persisted 数据：descriptor JSON 里没有 parameters 字段。
        let legacyJSON = """
        {
          "id": "p::m",
          "providerID": "p",
          "name": "m",
          "capability": "chat",
          "isEnabled": true,
          "isCustom": false
        }
        """
        let decoded = try JSONDecoder().decode(AIModelDescriptor.self, from: Data(legacyJSON.utf8))
        #expect(decoded.parameters == nil)
        #expect(decoded.name == "m")
        #expect(decoded.capability == .chat)
    }

    @Test("AI: 非法 provider / search mode 回退到默认")
    func aiInvalidRawValuesFallback() {
        let defaults = makeIsolatedDefaults()
        defaults.set("bad-provider", forKey: "settings.ai.provider")
        defaults.set("bad-mode", forKey: "settings.search.mode")

        let s = AppSettings(defaults: defaults)
        #expect(s.aiProvider == .openAICompatible)
        #expect(s.smartSearchMode == .keyword)
    }
}

// MARK: - W4-4 D1：RepoSortOption comparator 单元测试
//
// 把 comparator 独立测试,与 HomeViewModel 解耦 — 排序逻辑是纯函数,
// 不必走 SwiftUI / DB,几行 sort() 就能覆盖完。
@Suite("RepoSortOption")
struct RepoSortOptionTests {

    private func makeRepo(
        id: Int64,
        fullName: String = "octo/repo",
        stars: Int = 0,
        starredAt: String? = nil,
        pushedAt: String? = nil
    ) -> Repo {
        Repo(
            id: id, owner: "octo", name: "repo", fullName: fullName,
            description: nil, language: nil,
            starsCount: stars, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://x", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: pushedAt, createdAt: nil, updatedAt: nil,
            starredAt: starredAt, cachedAt: nil
        )
    }

    @Test("starredAtDesc: 最近 star 在前")
    func starredAtDesc() {
        let a = makeRepo(id: 1, starredAt: "2026-01-01T00:00:00Z")
        let b = makeRepo(id: 2, starredAt: "2026-05-01T00:00:00Z")
        let sorted = [a, b].sorted(by: RepoSortOption.starredAtDesc.comparator)
        #expect(sorted.map(\.id) == [2, 1])
    }

    @Test("nameAsc / nameDesc")
    func nameSort() {
        let a = makeRepo(id: 1, fullName: "zoo/swift")
        let b = makeRepo(id: 2, fullName: "Apple/Swift")
        let c = makeRepo(id: 3, fullName: "ggerganov/llama.cpp")

        let asc = [a, b, c].sorted(by: RepoSortOption.nameAsc.comparator)
        #expect(asc.map(\.id) == [2, 3, 1], "大小写不敏感升序: Apple < ggerganov < zoo")

        let desc = [a, b, c].sorted(by: RepoSortOption.nameDesc.comparator)
        #expect(desc.map(\.id) == [1, 3, 2])
    }

    @Test("starsDesc / starsAsc")
    func starsSort() {
        let a = makeRepo(id: 1, stars: 100)
        let b = makeRepo(id: 2, stars: 5)
        let c = makeRepo(id: 3, stars: 1000)
        let desc = [a, b, c].sorted(by: RepoSortOption.starsDesc.comparator)
        #expect(desc.map(\.id) == [3, 1, 2])
        let asc = [a, b, c].sorted(by: RepoSortOption.starsAsc.comparator)
        #expect(asc.map(\.id) == [2, 1, 3])
    }

    @Test("updatedDesc 用 pushedAt")
    func updatedSort() {
        let a = makeRepo(id: 1, pushedAt: "2026-05-01T00:00:00Z")
        let b = makeRepo(id: 2, pushedAt: "2026-05-30T00:00:00Z")
        let c = makeRepo(id: 3, pushedAt: nil)
        let desc = [a, b, c].sorted(by: RepoSortOption.updatedDesc.comparator)
        #expect(desc.first?.id == 2)
        #expect(desc.last?.id == 3, "nil pushedAt 应排到末尾")
    }
}
