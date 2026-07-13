//
//  RAGCitationChunkPopover.swift
//  Starcat
//
//  「命中的分片」全文 popover：回答内 S1/芯片与 Inspector 预览共用同一内容壳。
//

import SwiftUI

/// 命中分片全文：固定宽度 + 可滚动，避免长 README 分片撑爆 popover。
struct RAGCitationChunkPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let chunk: RAGChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("rag.workspace.inspector.chunkPreview")
                .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)

            ScrollView {
                Text(chunk.content)
                    .font(ragFont(.caption, scale: interfaceScale))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)

            if chunk.isTruncated {
                Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                    .font(ragFont(.caption, scale: interfaceScale))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .appLocaleEnvironment()
    }
}

/// 引用无 chunk 时的空态，避免点了 S1 却弹出空白框。
struct RAGCitationChunkMissingPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Label("rag.workspace.inspector.chunkMissing", systemImage: "exclamationmark.triangle.fill")
            .font(ragFont(.caption, scale: interfaceScale))
            .foregroundStyle(.orange)
            .padding(14)
            .frame(width: 280, alignment: .leading)
            .appLocaleEnvironment()
    }
}
