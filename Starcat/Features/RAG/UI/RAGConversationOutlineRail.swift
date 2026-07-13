//
//  RAGConversationOutlineRail.swift
//  Starcat
//
//  RAG 中栏左侧的会话大纲导航：完整问答轮次 → 短横线轨。
//
//  产品约定（2026-07-13）：
//  - 一条横线 = 一轮完整问答（user + 已落库 assistant）；未完成轮不出条。
//  - 默认只显示短横；hover 变亮变长并弹出预览卡；点击跳到该轮用户问题。
//  - 不做滚动位置联动高亮；条数不设上限，轨内可滚但隐藏滚动条。
//

import SwiftUI

/// 一轮完整问答在大纲轨上的投影。
struct RAGConversationOutlineTurn: Identifiable, Equatable {
    /// 用用户消息 id 作为跳转锚点与列表身份。
    var id: UUID { userMessageID }
    let userMessageID: UUID
    let title: String
    let preview: String
    let timestampISO8601: String
}

enum RAGConversationOutlineBuilder {
    /// 从消息流里只抽出「user 紧跟 assistant」的完整轮次；孤儿消息直接跳过。
    static func completeTurns(from messages: [RAGStoredMessage]) -> [RAGConversationOutlineTurn] {
        var turns: [RAGConversationOutlineTurn] = []
        var index = 0
        while index < messages.count {
            let current = messages[index]
            guard current.role == .user,
                  index + 1 < messages.count,
                  messages[index + 1].role == .assistant
            else {
                index += 1
                continue
            }
            let assistant = messages[index + 1]
            turns.append(
                RAGConversationOutlineTurn(
                    userMessageID: current.id,
                    title: firstLine(current.content),
                    preview: previewBody(assistant.content),
                    timestampISO8601: assistant.createdAt.isEmpty ? current.createdAt : assistant.createdAt
                )
            )
            index += 2
        }
        return turns
    }

    /// 标题取用户问题首行，超长截断，避免预览卡被单行撑爆。
    static func firstLine(_ text: String, limit: Int = 48) -> String {
        let raw = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return truncate(raw.trimmingCharacters(in: .whitespacesAndNewlines), to: limit)
    }

    /// 正文取助手回答前 N 字，并压成单段空白，便于扫读。
    static func previewBody(_ text: String, limit: Int = 120) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(collapsed, to: limit)
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped + "…"
    }
}

/// 中栏左侧大纲轨：短横列表 + hover 预览卡。
struct RAGConversationOutlineRail: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    let turns: [RAGConversationOutlineTurn]
    let onSelect: (RAGConversationOutlineTurn) -> Void
    let timeLabel: (String) -> String

    @State private var hoveredTurnID: UUID?
    @State private var hoverClearTask: Task<Void, Never>?

    private let idleDashWidth: CGFloat = 10
    private let activeDashWidth: CGFloat = 16
    private let dashHeight: CGFloat = 2
    private let dashSpacing: CGFloat = 4
    private let previewCardWidth: CGFloat = 280

    var body: some View {
        GeometryReader { proxy in
            dashTrack(containerHeight: proxy.size.height)
                // 预览卡叠在横线右侧，不参与布局宽度，避免出现/消失时左右撑开。
                .overlay(alignment: .leading) {
                    if let turn = turns.first(where: { $0.id == hoveredTurnID }) {
                        previewCard(turn)
                            .offset(x: activeDashWidth + 14)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveredTurnID)
        }
        // 只占横线轨宽度，预览卡画出边界外；不要拉满中栏，否则会挡住消息点击。
        .frame(width: activeDashWidth + 4)
        .onDisappear {
            hoverClearTask?.cancel()
            hoverClearTask = nil
            hoveredTurnID = nil
        }
    }

    private func dashTrack(containerHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: dashSpacing) {
                ForEach(turns) { turn in
                    dashButton(turn)
                }
            }
            .frame(maxWidth: .infinity)
            // 内容矮于视口时垂直居中；超出后自然可滚。
            .frame(minHeight: containerHeight, alignment: .center)
        }
        .frame(width: activeDashWidth + 4)
        .frame(maxHeight: .infinity)
    }

    private func dashButton(_ turn: RAGConversationOutlineTurn) -> some View {
        let isHovered = hoveredTurnID == turn.id
        return Button {
            onSelect(turn)
        } label: {
            Capsule()
                .fill(isHovered ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.45))
                .frame(
                    width: isHovered ? activeDashWidth : idleDashWidth,
                    height: dashHeight
                )
                .frame(width: activeDashWidth, height: dashHeight + 6, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.workspace.outline.jump")
        .accessibilityLabel(Text("rag.workspace.outline.jump"))
        .pointerStyle(.link)
        .onHover { hovering in
            updateHover(turnID: turn.id, isHovered: hovering)
        }
    }

    private func previewCard(_ turn: RAGConversationOutlineTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.title)
                .font(interfaceScale.font(.rowTitle, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !turn.preview.isEmpty {
                Text(turn.preview)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(timeLabel(turn.timestampISO8601))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: previewCardWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { hovering in
            updateHover(turnID: turn.id, isHovered: hovering)
        }
    }

    /// 横线与预览卡之间有空隙；短暂延迟清除，避免移入卡片时闪断。
    private func updateHover(turnID: UUID, isHovered: Bool) {
        hoverClearTask?.cancel()
        hoverClearTask = nil
        if isHovered {
            hoveredTurnID = turnID
            return
        }
        hoverClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            if hoveredTurnID == turnID {
                hoveredTurnID = nil
            }
        }
    }
}
