//
//  RAGChunkSource+Presentation.swift
//  Starcat
//
//  RAG 分片来源的 UI 呈现：图标 + 颜色 + 本地化标题。
//
//  芯片与右侧证据列表共用同一套映射；同 repo 不同 source 靠图标/颜色区分，
//  芯片文案只保留 `Sn · owner/repo`，不再堆 sectionTitle。
//

import SwiftUI

extension RAGChunkSource {
    /// 来源类型 → SF Symbol；芯片与右侧引用列表 / 命中分片 popover 必须一致。
    var systemImageName: String {
        switch self {
        case .readme: return "books.vertical.circle"
        case .notes: return "square.and.pencil.circle"
        case .summary: return "character.bubble"
        case .metadata: return "tag.circle"
        }
    }

    /// 来源类型 → 图标色；与 systemImageName 同枚举分支，避免两处漂移。
    var tintColor: Color {
        switch self {
        case .readme: return .blue
        case .notes: return .orange
        case .summary: return .purple
        case .metadata: return .teal
        }
    }

    /// 来源类型 → 本地化标题 key（与知识库浏览器同源）。
    var titleKey: LocalizedStringKey {
        switch self {
        case .readme: return "rag.browser.source.readme"
        case .notes: return "rag.browser.source.notes"
        case .summary: return "rag.browser.source.summary"
        case .metadata: return "rag.browser.source.metadata"
        }
    }
}

extension RAGCitationSource {
    /// 两个 XML 是仓库级临时证据，使用独立图标；其它来源保持与分片一致。
    var systemImageName: String {
        switch self {
        case .readme: return "books.vertical.circle"
        case .notes: return "square.and.pencil.circle"
        case .summary: return "character.bubble"
        case .metadata: return "tag.circle"
        case .knowledgeBaseMetadata: return "cylinder.split.1x2"
        case .repositoryInsights: return "gauge.with.dots.needle.bottom.0percent"
        case .repoContext: return "brain"
        }
    }

    var tintColor: Color {
        switch self {
        case .readme: return .blue
        case .notes: return .orange
        case .summary: return .purple
        case .metadata: return .teal
        case .knowledgeBaseMetadata: return .teal
        case .repositoryInsights: return .orange
        case .repoContext: return .indigo
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .readme: return "rag.browser.source.readme"
        case .notes: return "rag.browser.source.notes"
        case .summary: return "rag.browser.source.summary"
        case .metadata: return "rag.browser.source.metadata"
        case .knowledgeBaseMetadata: return "rag.workspace.citation.knowledgeBaseMetadata"
        case .repositoryInsights: return "rag.browser.repositoryInsights.title"
        case .repoContext: return "rag.workspace.repoContext.title"
        }
    }
}

extension RAGCitation {
    /// 全局结构化证据没有仓库身份；复用 source 标题可避免伪造 owner/repo 和头像。
    var localizedIdentityTitle: String {
        source == .knowledgeBaseMetadata
            ? String.l10n("rag.workspace.citation.knowledgeBaseMetadata")
            : repoFullName
    }

    /// 结构化元数据使用稳定 section id 持久化，显示时再映射当前 App 语言。
    var localizedSectionTitle: String {
        guard source == .knowledgeBaseMetadata else { return sectionTitle }
        let key: String
        switch sectionTitle {
        case "scope": key = "rag.workspace.citation.section.scope"
        case "organization": key = "rag.workspace.citation.section.organization"
        case "technology": key = "rag.workspace.citation.section.technology"
        case "activity_quality": key = "rag.workspace.citation.section.activityQuality"
        case "knowledge_artifacts": key = "rag.workspace.citation.section.knowledgeArtifacts"
        case "index_coverage": key = "rag.workspace.citation.section.indexCoverage"
        case "star_leaders": key = "rag.workspace.citation.section.starLeaders"
        case "index_health": key = "rag.workspace.citation.section.indexHealth"
        default: return sectionTitle
        }
        return String.l10n(key)
    }
}

extension RAGHitKind {
    /// 用户可见命中方式必须说明 FTS5，不能直接暴露内部 rawValue `keyword`。
    var localizedTitle: String {
        let key = switch self {
        case .keyword: "rag.workspace.inspector.matchType.keyword"
        case .vector: "rag.workspace.inspector.matchType.vector"
        case .hybrid: "rag.workspace.inspector.matchType.hybrid"
        case .structured: "rag.workspace.inspector.matchType.structured"
        case .repositoryInsights: "rag.browser.repositoryInsights.title"
        case .repoContext: "rag.workspace.repoContext.title"
        }
        return String.l10n(key)
    }
}
