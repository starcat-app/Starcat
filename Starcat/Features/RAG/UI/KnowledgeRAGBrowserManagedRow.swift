//
//  KnowledgeRAGBrowserManagedRow.swift
//  Starcat
//
//  知识库浏览器右栏的稳定行快照，避免 SwiftUI 每次 body 求值都复制并枚举完整数组。
//

import Foundation

/// 把展示顺序固化在数据变更边界，既保留稳定业务 ID，也为斑马纹提供固定行号。
struct KnowledgeRAGBrowserManagedRow: Identifiable {
    let index: Int
    let item: KnowledgeRAGBrowserManagedItem

    var id: String { item.id }

    static func make(from items: [KnowledgeRAGBrowserManagedItem]) -> [Self] {
        items.enumerated().map { index, item in
            Self(index: index, item: item)
        }
    }
}
