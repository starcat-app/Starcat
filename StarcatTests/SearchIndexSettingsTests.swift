//
//  SearchIndexSettingsTests.swift
//  StarcatTests
//
//  搜索与索引表单重组后的配置契约：六项配置仍写原字段，
//  预设同步具体阈值，自定义保留当前比例，搜索过滤不与重建规则串用。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("SearchIndexSettings")
struct SearchIndexSettingsTests {
    /// 每例独立持久化域，防止修改开发者实际模型和索引偏好。
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.starcat.searchIndex.\(UUID().uuidString)")!
    }

    @Test("固定预设同步两项比例并持久化", arguments: [
        AIIndexPreset.strict, .standard, .relaxed
    ])
    func presetPersistsEffectiveThresholds(_ preset: AIIndexPreset) {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.aiSemanticSearchScoreThreshold = 0.83
        settings.aiReadmeTruncateLength = 24000
        settings.aiIndexAutoPrefetchEnabled = true
        settings.applyAIIndexPreset(preset)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiIndexPreset == preset)
        #expect(reloaded.aiIndexBodyDiffRatio == preset.thresholds.bodyDiffRatio)
        #expect(reloaded.aiIndexNotesDiffRatio == preset.thresholds.notesDiffRatio)
        #expect(reloaded.aiIndexThresholds == preset.thresholds)
        // 重建规则不能覆盖搜索过滤、内容长度或自动预拉。
        #expect(reloaded.aiSemanticSearchScoreThreshold == 0.83)
        #expect(reloaded.aiReadmeTruncateLength == 24000)
        #expect(reloaded.aiIndexAutoPrefetchEnabled)
    }

    @Test("切到自定义保留当前比例，编辑后重开仍生效")
    func customRetainsAndPersistsRatios() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.applyAIIndexPreset(.relaxed)
        settings.applyAIIndexPreset(.custom)
        #expect(settings.aiIndexBodyDiffRatio == 0.20)
        #expect(settings.aiIndexNotesDiffRatio == 0.30)

        settings.aiIndexBodyDiffRatio = 0.17
        settings.aiIndexNotesDiffRatio = 0.43
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiIndexPreset == .custom)
        #expect(reloaded.aiIndexThresholds == DiffThresholds(bodyDiffRatio: 0.17, notesDiffRatio: 0.43))
    }

    @Test("搜索相似度只过滤结果，不改变重建阈值")
    func searchThresholdDoesNotChangeRebuildRules() {
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.applyAIIndexPreset(.strict)
        settings.aiSemanticSearchScoreThreshold = 0.99
        #expect(settings.aiIndexPreset == .strict)
        #expect(settings.aiIndexThresholds == AIIndexPreset.strict.thresholds)

        settings.applyAIIndexPreset(.relaxed)
        #expect(settings.aiSemanticSearchScoreThreshold == 0.99)
    }

    @Test("仓库全部处理失败不能显示已完成，部分失败显示警告")
    func repositoryFailuresAreNotSuccess() {
        #expect(SearchIndexStatus.repository(
            status: .completed(processed: 2061, total: 2061), failures: 2061, lastRun: nil
        ) == .failed)
        #expect(SearchIndexStatus.repository(
            status: .completed(processed: 2061, total: 2061), failures: 7, lastRun: nil
        ) == .partialFailure)
        #expect(SearchIndexStatus.repository(
            status: .completed(processed: 2061, total: 2061), failures: 0, lastRun: nil
        ) == .completed)
    }

    @Test("重开页面后落盘的失败结果仍显示失败")
    func persistedRepositoryFailureIsVisible() {
        let record = SemanticIndexPrefetchLastRun(
            finishedAt: Date(), processed: 2061, total: 2061,
            failures: 2061, outcome: .completed, failureMessage: nil
        )
        #expect(SearchIndexStatus.repository(status: .idle, failures: 0, lastRun: record) == .failed)
        // 新一轮运行和暂停状态必须覆盖上次失败，避免用户重试后仍显示旧结果。
        #expect(SearchIndexStatus.repository(status: .running, failures: 0, lastRun: record) == .running)
        #expect(SearchIndexStatus.repository(status: .paused, failures: 0, lastRun: record) == .paused)
    }

    @Test("知识库文本全部可检索仍要保留向量失败或过期提示")
    func keywordCoverageDoesNotMaskEmbeddingIssues() {
        let failed = RAGIndexStatusProjection(
            knowledgeRepoCount: 3, indexedRepoCount: 3, totalChunks: 96,
            readyChunks: 96, pendingChunks: 0, failedChunks: 32, staleChunks: 93
        )
        #expect(SearchIndexStatus.knowledge(
            status: .completed(failed), coverage: failed, hasModel: true
        ) == .partialFailure)
        let stale = RAGIndexStatusProjection(
            knowledgeRepoCount: 3, indexedRepoCount: 3, totalChunks: 96,
            readyChunks: 96, pendingChunks: 0, failedChunks: 0, staleChunks: 93
        )
        #expect(SearchIndexStatus.knowledge(
            status: .completed(stale), coverage: stale, hasModel: true
        ) == .needsUpdate)
    }

    @Test("没有向量模型时只声明关键词可用")
    func textReadyWithoutEmbeddingModel() {
        let text = RAGIndexStatusProjection(
            knowledgeRepoCount: 3, indexedRepoCount: 3, totalChunks: 96,
            readyChunks: 96, pendingChunks: 0, failedChunks: 0, staleChunks: 0
        )
        #expect(SearchIndexStatus.knowledge(
            status: .completed(text), coverage: text, hasModel: false
        ) == .textReady)
        #expect(SearchIndexStatus.knowledge(
            status: .completed(text), coverage: text, hasModel: true
        ) == .completed)
    }

    @Test("知识库构建阶段和连接失败优先于旧覆盖统计")
    func knowledgeLiveStatusOverridesCoverage() {
        #expect(SearchIndexStatus.knowledge(
            status: .embedding(processedChunks: 12, totalChunks: 96),
            coverage: .empty, hasModel: true
        ) == .building)
        #expect(SearchIndexStatus.knowledge(
            status: .failed("unreachable"), coverage: .empty, hasModel: true
        ) == .failed)
    }
}
