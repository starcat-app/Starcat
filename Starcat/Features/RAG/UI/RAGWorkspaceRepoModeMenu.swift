//
//  RAGWorkspaceRepoModeMenu.swift
//  Starcat
//
//  RAG Composer 的显式仓库范围菜单，隔离消息时间线更新。
//

import SwiftUI

/// 只观察仓库范围模式的轻量菜单，避免消息加载让 AppKit 重建固定的三项菜单。
struct RAGWorkspaceRepoModeMenu: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    var body: some View {
        Menu {
            // Text("key") 走 LocalizedStringKey；勿把 String 字面量传进 Text，否则会显示 raw key。
            Picker("", selection: $viewModel.explicitRepoMode) {
                Text("rag.workspace.repoMode.only").tag(RAGExplicitRepoMode.only)
                Text("rag.workspace.repoMode.prefer").tag(RAGExplicitRepoMode.prefer)
                Text("rag.workspace.repoMode.exclude").tag(RAGExplicitRepoMode.exclude)
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                // 与模型菜单的 14pt 品牌 logo 对齐，保持底栏两个菜单视觉等大。
                Image(systemName: "scope")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text(repoModeKey)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .ragComposerMenuLabelStyle(font: ragFont(.caption, scale: interfaceScale, weight: .semibold))
        .fixedSize()
        .help("rag.workspace.composer.scope")
    }

    private var repoModeKey: LocalizedStringKey {
        switch viewModel.explicitRepoMode {
        case .only: "rag.workspace.repoMode.only"
        case .prefer: "rag.workspace.repoMode.prefer"
        case .exclude: "rag.workspace.repoMode.exclude"
        }
    }
}
