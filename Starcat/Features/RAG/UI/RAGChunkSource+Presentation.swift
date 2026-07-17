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
    /// RepoContext 是仓库级临时证据，使用独立 brain 图标；其它来源保持与分片一致。
    var systemImageName: String {
        switch self {
        case .readme: return "books.vertical.circle"
        case .notes: return "square.and.pencil.circle"
        case .summary: return "character.bubble"
        case .metadata: return "tag.circle"
        case .repoContext: return "brain"
        }
    }

    var tintColor: Color {
        switch self {
        case .readme: return .blue
        case .notes: return .orange
        case .summary: return .purple
        case .metadata: return .teal
        case .repoContext: return .indigo
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .readme: return "rag.browser.source.readme"
        case .notes: return "rag.browser.source.notes"
        case .summary: return "rag.browser.source.summary"
        case .metadata: return "rag.browser.source.metadata"
        case .repoContext: return "rag.workspace.repoContext.title"
        }
    }
}
