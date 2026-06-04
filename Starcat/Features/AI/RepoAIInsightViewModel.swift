//
//  RepoAIInsightViewModel.swift
//  Starcat
//
//  详情页单仓 AI 摘要状态模型。
//
//  模块职责：
//  - 管理 AI 摘要的未生成 / 加载缓存 / 生成中 / 失败状态；
//  - 提供“生成 / 重新生成”动作；
//  - 承接 AI 标签推荐确认流，用户点击后才创建标签并绑定到 repo。
//
//  关键约束：
//  - 只在用户操作时调用 AI，不自动批量生成；
//  - 标签应用是显式动作，AI 结果本身不会直接修改用户数据；
//  - 成功应用标签后通知 HomeViewModel 刷新 Sidebar 计数与当前列表。
//

import Foundation
import Observation

@MainActor
@Observable
final class RepoAIInsightViewModel {

    private(set) var insight: RepoAIInsight?
    private(set) var isLoading: Bool = false
    private(set) var isGenerating: Bool = false
    private(set) var errorMessage: String?
    private(set) var tagErrorMessage: String?
    private(set) var streamingSummaryText: String?
    private(set) var appliedTagNames: Set<String> = []

    private let service: RepoAIInsightService
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    var onTagsChanged: (() -> Void)?

    init(
        service: RepoAIInsightService,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.service = service
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    func load(repo: Repo) async {
        isLoading = true
        defer { isLoading = false }
        do {
            insight = try await service.cachedInsight(for: repo)
            let currentTags = try await repoTagRepository.fetchTags(forRepo: repo.id)
            appliedTagNames = Set(currentTags.map { $0.name.normalizedTagName })
            errorMessage = nil
            tagErrorMessage = nil
            streamingSummaryText = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate(repo: Repo) async {
        isGenerating = true
        streamingSummaryText = ""
        defer {
            isGenerating = false
            streamingSummaryText = nil
        }
        do {
            let result = try await service.generateInsight(for: repo) { [weak self] partial in
                self?.streamingSummaryText = partial
            }
            insight = result.insight
            tagErrorMessage = result.tagErrorMessage
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyTag(_ suggestion: AITagSuggestion, repo: Repo) async {
        let tagName = suggestion.name.normalizedTagName
        guard !tagName.isEmpty, !appliedTagNames.contains(tagName) else { return }
        do {
            let tag = try await findOrCreateTag(named: tagName)
            try await repoTagRepository.addTag(repoId: repo.id, tagId: tag.id)
            appliedTagNames.insert(tagName)
            onTagsChanged?()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyAllTags(repo: Repo) async {
        guard let insight else { return }
        for suggestion in insight.suggestedTags {
            await applyTag(suggestion, repo: repo)
        }
    }

    private func findOrCreateTag(named name: String) async throws -> Tag {
        if let existing = try await tagRepository.findByName(name) {
            return existing
        }
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let tag = Tag(
            id: UUID().uuidString,
            name: name,
            color: nil,
            icon: "tag",
            sortOrder: 0,
            isPreset: false,
            parentId: nil,
            createdAt: now,
            updatedAt: now
        )
        try await tagRepository.create(tag)
        return tag
    }
}

private extension String {
    var normalizedTagName: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
