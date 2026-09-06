//
//  RAGConversationRailPresentation.swift
//  Starcat
//
//  RAG 会话侧栏的稳定分桶快照，避免 SwiftUI 刷新时按分组重复扫描完整会话数组。
//

import Foundation

/// 会话侧栏一次数据发布对应的完整展示快照。
///
/// 会话数量和分组数量都可能持续增长。若在 `body` 内分别过滤置顶、未分组和每个分组，
/// 一次 hover 就会触发 `O(groupCount * conversationCount)` 的重复工作。这里用一次遍历
/// 换取少量行快照内存，让 View 只消费已经分桶并带稳定下标的数据。
struct RAGConversationRailPresentation {
    enum Placement: Hashable {
        case pinned
        case ungrouped
        case group(UUID)
    }

    struct Row: Identifiable {
        struct ID: Hashable {
            let conversationID: UUID
            let placement: Placement
        }

        let conversation: RAGConversationSummary
        let rowIndex: Int
        let placement: Placement

        var id: ID {
            ID(conversationID: conversation.id, placement: placement)
        }
    }

    static let empty = RAGConversationRailPresentation(conversations: [], groups: [])

    let pinnedRows: [Row]
    let ungroupedRows: [Row]
    let groupIDs: [UUID]
    private let groupedRowsByID: [UUID: [Row]]

    init(
        conversations: [RAGConversationSummary],
        groups: [RAGConversationGroup]
    ) {
        var pinnedRows: [Row] = []
        var ungroupedRows: [Row] = []
        var groupedRowsByID: [UUID: [Row]] = [:]
        pinnedRows.reserveCapacity(conversations.count)
        ungroupedRows.reserveCapacity(conversations.count)
        groupedRowsByID.reserveCapacity(groups.count)

        for conversation in conversations {
            if conversation.isPinned {
                pinnedRows.append(Row(
                    conversation: conversation,
                    rowIndex: pinnedRows.count,
                    placement: .pinned
                ))
            } else if let groupID = conversation.groupID {
                let rowIndex = groupedRowsByID[groupID]?.count ?? 0
                groupedRowsByID[groupID, default: []].append(Row(
                    conversation: conversation,
                    rowIndex: rowIndex,
                    placement: .group(groupID)
                ))
            } else {
                ungroupedRows.append(Row(
                    conversation: conversation,
                    rowIndex: ungroupedRows.count,
                    placement: .ungrouped
                ))
            }
        }

        self.pinnedRows = pinnedRows
        self.ungroupedRows = ungroupedRows
        self.groupIDs = groups.map(\.id)
        self.groupedRowsByID = groupedRowsByID
    }

    func rows(inGroupID groupID: UUID) -> [Row] {
        groupedRowsByID[groupID] ?? []
    }
}
