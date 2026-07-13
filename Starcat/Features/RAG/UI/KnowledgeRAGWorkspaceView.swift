//
//  KnowledgeRAGWorkspaceView.swift
//  Starcat
//
//  知识库 RAG 三栏工作台的窗口级容器。
//

import SwiftUI

struct KnowledgeRAGWorkspaceView: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppDependencies.self) private var dependencies

    @Bindable var chromeState: WorkspaceChromeState
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    var body: some View {
        HStack(spacing: 0) {
            if !chromeState.isLeftColumnCollapsed {
                RAGWorkspaceConversationRail(viewModel: viewModel)
                    .frame(width: 286)
                Divider()
            }

            RAGWorkspaceAnswerSurface(viewModel: viewModel)
                .layoutPriority(1)

            if !chromeState.isRightColumnCollapsed {
                Divider()
                RAGWorkspaceInspector(viewModel: viewModel)
                    .frame(minWidth: 320, idealWidth: 356, maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeKnowledgeBoundaryChanges() }
        .task { await viewModel.observeIndexChanges() }
        .environment(\.openURL, OpenURLAction { url in
            if viewModel.openCitationLink(url) { return .handled }
            viewModel.handleLink(url)
            return .handled
        })
        .sheet(isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.dismissError() } })) {
            RAGWorkspaceErrorSheet(
                error: viewModel.workspaceError ?? .init(technicalDetail: viewModel.errorMessage ?? ""),
                onAction: viewModel.resolveWorkspaceErrorAction,
                onDismiss: viewModel.dismissError
            )
                .appLocaleEnvironment()
        }
        .sheet(isPresented: $chromeState.isPromptSettingsPresented) {
            RAGWorkspacePromptSettingsSheet(settings: dependencies.settings)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isLeftColumnCollapsed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }
}
