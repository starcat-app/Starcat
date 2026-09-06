//
//  RAGWorkspaceModelMenu.swift
//  Starcat
//
//  RAG Composer 的模型选择菜单，隔离回答时间线的高频状态更新。
//

import SwiftUI

/// 独立观察模型配置的菜单。
///
/// 回答时间线和会话骨架更新不应让 AppKit 重新生成模型菜单项；只有模型配置、当前选择
/// 或推理后端变化时，本视图才需要重新求值。
struct RAGWorkspaceModelMenu: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    var body: some View {
        Menu {
            // inline Picker 让系统只给当前 selection 打勾；模型数组由 ViewModel 缓存，
            // 设置未变化时不会在每次会话切换中重新过滤、排序并生成菜单身份。
            Picker("", selection: $viewModel.selectedModelID) {
                ForEach(viewModel.availableModels) { model in
                    modelPickerLabel(model)
                        .tag(Optional(model.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let provider = viewModel.selectedModelProvider {
                    AIProviderIconView(provider: provider, size: 14)
                } else {
                    // fallback 固定 14×14，避免切换 API / CLI 后菜单标签宽度跳动。
                    Image(systemName: "sparkles")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.selectedModelDisplayName)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .ragComposerMenuLabelStyle(font: ragFont(.caption, scale: interfaceScale, weight: .semibold))
        .fixedSize()
        // CLI 后端由 RAG 设置统一选择；保留 API 模型偏好，但不能让用户误以为 CLI 会使用它。
        .disabled(!viewModel.usesAPIInferenceBackend)
        .help("rag.workspace.composer.model")
    }

    /// providerID 是配置 profile ID，必须经 ViewModel 映射后才能展示正确服务商图标。
    @ViewBuilder
    private func modelPickerLabel(_ model: AIModelDescriptor) -> some View {
        if let provider = viewModel.provider(for: model) {
            Label {
                Text(model.name)
            } icon: {
                AIProviderIconView(provider: provider, size: 15)
            }
        } else {
            Label(model.name, systemImage: "sparkles")
        }
    }
}
