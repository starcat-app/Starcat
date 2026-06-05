//
//  AIModelListView.swift
//  Starcat
//
//  AI 设置页模型列表组件。
//
//  模块职责：
//  - 展示单个 provider profile 通过 `/models` 发现的模型；
//  - 支持在本组件内部搜索、启用 / 禁用模型、修正 Chat / Embedding 能力；
//  - 限制模型列表高度，避免 LM Studio / OpenRouter 返回大量模型时把整个 Settings 页面无限拉长。
//
//  关键约束：
//  - 模型能力不是所有 OpenAI-compatible 服务都会返回统一字段，因此能力 Picker 是用户可修正项。
//  - 组件只负责展示和绑定，不直接修改 AppSettings；实际写入由父视图提供 Binding，便于测试和复用。
//

import SwiftUI

/// Provider 模型列表的受限高度展示组件。
struct AIModelListView: View {

    let profile: AIProviderProfile
    let enabledBinding: (AIModelDescriptor) -> Binding<Bool>
    let capabilityBinding: (AIModelDescriptor) -> Binding<AIModelCapability>

    @State private var query = ""

    private var filteredModels: [AIModelDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return profile.models }
        return profile.models.filter { model in
            model.name.localizedCaseInsensitiveContains(trimmed)
                || (model.ownedBy?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || model.capability.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            modelScroll
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack {
            Text("\(profile.models.count) 个模型")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("匹配 \(filteredModels.count) 个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var searchField: some View {
        TextField("过滤模型名称、owner 或能力", text: $query)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
    }

    private var modelScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredModels.isEmpty {
                    Text("没有匹配的模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                        if model.id != filteredModels.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        // HOM-68 follow-up v2 (2026-06-05 22:30 dong4j 反馈)：原 260pt 高度太占空间，
        // 压到约能完整展示 4 条模型行的高度。每条 modelRow ≈ 36pt（content 22pt +
        // vertical padding 14pt）+ Divider 1pt，4 行 ≈ 148pt，给点缓冲取 160pt。
        .frame(height: 160)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
    }

    private func modelRow(_ model: AIModelDescriptor) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: enabledBinding(model)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ownedBy = model.ownedBy, !ownedBy.isEmpty {
                        Text(ownedBy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: capabilityBinding(model)) {
                ForEach(AIModelCapability.allCases) { capability in
                    Text(capability.displayName).tag(capability)
                }
            }
            .labelsHidden()
            .frame(width: 132)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
