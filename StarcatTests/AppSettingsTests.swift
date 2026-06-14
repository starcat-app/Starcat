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

    // R-01 §3.1.1（2026-06-10 P1）：RepoListDensity 枚举 + AppSettings.listDensity
    // 属性已彻底删除。原 defaultDensity / densityPersists / invalidValueFallsBack
    // 三个测试随之失效（之前为保签名稳定保留单 case 是「自留技术债」，现在所有
    // row / skeleton 视图直接用 card 密度）。

    @Test("Pro: 默认非 Pro，设置后重新读取应保留")
    func proStatusPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        #expect(s1.isProUser == false)

        s1.isProUser = true

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.isProUser == true)
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
        // 2026-06-14 v4 占位符归一化（dong4j 拍板）：
        // 旧 `{context}` 黑盒拆成 5 个透明占位符（{outputLanguage} + {metadata} +
        // {readme} + {codeContext} + {externalContext}）；旧硬编中文章节标题
        // (`## 一句话总结` / `## 风险与注意点`) 改成英文 + 由 LLM 按 {outputLanguage} 自然翻译。
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("{metadata}"))
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("{readme}"))
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("{codeContext}"))
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("{externalContext}"))
        #expect(s.aiSummaryTask.prompt.userPromptTemplate.contains("{outputLanguage}"))
        #expect(s.aiSummaryTask.prompt.systemPrompt.contains("{outputLanguage}"))
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

    @Test("AI: provider 只有测试成功且启用后才算正式配置")
    func aiProviderProfileVerifiedState() {
        let draft = AIProviderProfile(
            id: "draft",
            provider: .deepSeek,
            lastTestStatus: .notTested
        )
        let failed = AIProviderProfile(
            id: "failed",
            provider: .deepSeek,
            lastTestStatus: .failed("401")
        )
        let disabled = AIProviderProfile(
            id: "disabled",
            provider: .deepSeek,
            isEnabled: false,
            lastTestStatus: .success(modelCount: 3)
        )
        let verified = AIProviderProfile(
            id: "verified",
            provider: .deepSeek,
            lastTestStatus: .success(modelCount: 3)
        )

        #expect(!draft.isVerifiedConfiguration)
        #expect(!failed.isVerifiedConfiguration)
        #expect(!disabled.isVerifiedConfiguration)
        #expect(verified.isVerifiedConfiguration)
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

// MARK: - HOM-126：AutoTidySettings 持久化 + 排序
//
// 验证 AutoTidySettings 的默认值、持久化往返、`sortOrder.pick` 行为，
// 以及 Codable forward-compat（缺字段 fallback）。
// 这些都是纯函数 / UserDefaults，无需 SwiftUI / DB / AI 调用。
@MainActor
@Suite("AutoTidySettings")
struct AutoTidySettingsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.autotidy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeRepo(id: Int64, starredAt: String? = nil) -> Repo {
        Repo(
            id: id, owner: "octo", name: "repo", fullName: "octo/r\(id)",
            description: nil, language: nil,
            starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://x", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil,
            starredAt: starredAt, cachedAt: nil
        )
    }

    @Test("默认值与 HOM-126 任务描述一致（开关关 + 启动/同步触发 + 50 + 最近 star + 仅标签 + 90%）")
    func defaultMatchesTaskSpec() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        let t = s.autoTidySettings
        #expect(t.enabled == false, "总开关默认关")
        #expect(t.triggerOnLaunch == true)
        #expect(t.triggerOnSync == true)
        #expect(t.triggerScheduled == false, "定时默认关，避免新手烧 quota")
        #expect(t.maxPerRun == 50)
        #expect(t.sortOrder == .recentlyStarred)
        #expect(t.generateSummary == false, "默认只跑标签，摘要烧 token 更多")
        #expect(t.generateTags == true)
        #expect(t.useConfidenceThreshold == true, "默认启用阈值过滤，保险地只应用高置信度标签")
        #expect(t.confidenceThreshold == 0.90)
        #expect(t.lastRunAt == nil)
        #expect(t.lastRunStats == nil)
    }

    @Test("设置后重新读取应保留全部字段")
    func roundTripPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)

        var t = s1.autoTidySettings
        t.enabled = true
        t.triggerScheduled = true
        t.maxPerRun = 200
        t.sortOrder = .random
        t.generateSummary = true
        t.useConfidenceThreshold = false
        t.confidenceThreshold = 0.75
        t.lastRunAt = Date(timeIntervalSince1970: 1_700_000_000)
        t.lastRunStats = AutoTidyLastRunStats(total: 50, applied: 40, ignored: 5, failed: 5)
        s1.autoTidySettings = t

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.autoTidySettings.enabled == true)
        #expect(s2.autoTidySettings.triggerScheduled == true)
        #expect(s2.autoTidySettings.maxPerRun == 200)
        #expect(s2.autoTidySettings.sortOrder == .random)
        #expect(s2.autoTidySettings.generateSummary == true)
        #expect(s2.autoTidySettings.useConfidenceThreshold == false)
        #expect(s2.autoTidySettings.confidenceThreshold == 0.75, "用户值在 toggle 关掉时也应保留，便于再次开启时还原")
        #expect(s2.autoTidySettings.lastRunAt?.timeIntervalSince1970 == 1_700_000_000)
        #expect(s2.autoTidySettings.lastRunStats?.applied == 40)
        #expect(s2.autoTidySettings.lastRunStats?.failed == 5)
    }

    @Test("Codable: 缺字段时回落到 default 字段值")
    func decodeForwardCompat() throws {
        // 模拟未来某个老 build 写的 JSON：只含部分字段，缺新字段也不应失败
        let partialJSON = #"{"enabled":true,"maxPerRun":123}"#
        let decoded = try JSONDecoder().decode(AutoTidySettings.self, from: Data(partialJSON.utf8))
        #expect(decoded.enabled == true)
        #expect(decoded.maxPerRun == 123)
        // 缺字段走 default
        #expect(decoded.sortOrder == .recentlyStarred)
        #expect(decoded.confidenceThreshold == 0.90)
        #expect(decoded.useConfidenceThreshold == true, "老 build 没写本字段，应该回落到 default = true（保持 v1 行为）")
        #expect(decoded.generateTags == true)
        #expect(decoded.generateSummary == false)
    }

    @Test("makeBatchOptions: 只勾摘要 → actions={summary}, autoApply=false")
    func batchOptionsSummaryOnly() {
        var t = AutoTidySettings.default
        t.generateSummary = true
        t.generateTags = false
        let opts = t.makeBatchOptions()
        #expect(opts.actions == [.summary])
        #expect(opts.autoApplyTags == false)
    }

    @Test("makeBatchOptions: 勾了标签 → autoApplyTags=true（自动模式明示同意）")
    func batchOptionsAutoApply() {
        let opts = AutoTidySettings.default.makeBatchOptions()
        #expect(opts.actions == [.tags])
        #expect(opts.autoApplyTags == true)
        #expect(opts.confidenceThreshold == 0.90)
    }

    @Test("makeBatchOptions: useConfidenceThreshold=false 时把 confidenceThreshold 降级为 0（不过滤）")
    func batchOptionsThresholdDisabled() {
        var t = AutoTidySettings.default
        t.useConfidenceThreshold = false
        t.confidenceThreshold = 0.75  // 用户历史值，should be preserved in settings but not passed down
        let opts = t.makeBatchOptions()
        #expect(opts.confidenceThreshold == 0, "toggle 关掉后下游收到 0，等价于不过滤、所有 AI 建议都应用")
        // 用户值未被破坏（仍保留在 settings 字段中），便于再次开启时还原
        #expect(t.confidenceThreshold == 0.75)
    }

    @Test("pick(recentlyStarred): 取最近 star 在前的 N 条")
    func pickRecentlyStarred() {
        let repos = [
            makeRepo(id: 1, starredAt: "2026-01-01T00:00:00Z"),
            makeRepo(id: 2, starredAt: "2026-05-01T00:00:00Z"),
            makeRepo(id: 3, starredAt: "2026-03-01T00:00:00Z"),
        ]
        let picked = AutoTidySortOrder.recentlyStarred.pick(from: repos, limit: 2)
        #expect(picked.map(\.id) == [2, 3])
    }

    @Test("pick(earliestStarred): 取最早 star 在前的 N 条，nil 排末")
    func pickEarliestStarred() {
        let repos = [
            makeRepo(id: 1, starredAt: "2026-01-01T00:00:00Z"),
            makeRepo(id: 2, starredAt: nil),
            makeRepo(id: 3, starredAt: "2026-03-01T00:00:00Z"),
        ]
        let picked = AutoTidySortOrder.earliestStarred.pick(from: repos, limit: 3)
        // 1 (earliest), 3 (later), 2 (nil → 末)
        #expect(picked.map(\.id) == [1, 3, 2])
    }

    @Test("pick(limit=0): 返回空")
    func pickZeroLimit() {
        let repos = [makeRepo(id: 1)]
        let picked = AutoTidySortOrder.recentlyStarred.pick(from: repos, limit: 0)
        #expect(picked.isEmpty)
    }
}

// MARK: - X2 RepoContextPacker 偏好（§0.3 X1）

/// X2（2026-06-13）：验证 3 个 RepoContextPacker 偏好字段的默认值 + 持久化往返。
///
/// 关键覆盖：
///   1. 默认值与 PackInput / TierTruncation 缺省值对齐（true / 8000 / 80）
///   2. 写入后新建实例能从 UserDefaults 读回
///   3. AppSettings 自身**不**对入参做 clamp——保护逻辑在 SwiftUI Stepper(in:) UI 层；
///      此测试只验证持久化的"诚实回读"语义（写多少读多少），防止有人加了"偷偷 clamp"
///      逻辑后破坏 Stepper 显示行为。真正 UI 层 clamp 由 SettingsView snapshot 测兜底。
@MainActor
@Suite("AppSettings.RepoContextPacker")
struct AppSettingsRepoContextTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.appsettings.repocontext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("默认值：enabled=true / tokenBudget=8000 / tier1MaxLines=80")
    func defaults() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        #expect(s.aiRepoContextEnabled == true)
        #expect(s.aiRepoContextTokenBudget == 8000)
        #expect(s.aiRepoContextTier1MaxLines == 80)
    }

    @Test("写入后新建实例能正确回读 3 个字段")
    func roundTripPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.aiRepoContextEnabled = false
        s1.aiRepoContextTokenBudget = 16000
        s1.aiRepoContextTier1MaxLines = 160

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.aiRepoContextEnabled == false)
        #expect(s2.aiRepoContextTokenBudget == 16000)
        #expect(s2.aiRepoContextTier1MaxLines == 160)
    }

    @Test("out-of-range 值会被原样持久化（clamp 由 Stepper UI 层负责）")
    func outOfRangeValuesPassThroughUnclamped() {
        // 行为契约：AppSettings 不对入参做 clamp（避免和 SwiftUI Stepper UI 重复约束）。
        // 此测试锁定"诚实回读"语义，防止以后误加"偷偷 clamp"破坏 Stepper 显示。
        let defaults = makeIsolatedDefaults()
        let s = AppSettings(defaults: defaults)
        s.aiRepoContextTokenBudget = 999_999
        s.aiRepoContextTier1MaxLines = -5

        #expect(s.aiRepoContextTokenBudget == 999_999)
        #expect(s.aiRepoContextTier1MaxLines == -5)

        // 新实例同样回读非 clamp 值
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.aiRepoContextTokenBudget == 999_999)
        #expect(s2.aiRepoContextTier1MaxLines == -5)
    }
}
