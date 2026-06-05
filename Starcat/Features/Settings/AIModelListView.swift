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
    /// HOM-68 follow-up v9：父视图提供"读取并写回 descriptor.parameters"的 nullable binding。
    /// nil 表示该模型没有用户级覆盖，使用 capability 默认。
    let parametersBinding: (AIModelDescriptor) -> Binding<AIModelParameters?>

    @State private var query = ""
    /// 当前正在编辑参数的模型；nil 表示无 popover 显示。
    /// 用 `.popover(item:)` 而非每行各自 isPresented 状态，避免点 A 行后再点 B 行
    /// 出现"两个 popover 同时浮动 / 旧 popover 留尾巴"的视觉 bug。
    @State private var popoverModel: AIModelDescriptor?

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

            // HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
            // 齿轮按钮 → 弹出模型参数编辑 popover。锚定到 plain Button 而不是
            // 整行，避免点击其它区域（toggle / capability picker）误触发 popover。
            // 已覆盖参数的模型 SF Symbol 显示 .fill 变体 + tint orange，给个轻量
            // "这个模型已自定义"视觉提示，与 popover header 的"已自定义"角标呼应。
            Button {
                popoverModel = model
            } label: {
                Image(systemName: parametersBinding(model).wrappedValue == nil ? "gearshape" : "gearshape.fill")
                    .foregroundStyle(parametersBinding(model).wrappedValue == nil ? Color.secondary : Color.orange)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            // HOM-68 follow-up v10 (dong4j 反馈 2026-06-05 23:55)：项目强制规则
            // (docs/详细设计/07-UI交互设计.md §1.2)——所有 .buttonStyle(.plain) 必
            // 须紧跟 .focusEffectDisabled() 抑制 macOS 15+ 默认蓝色 focus ring。
            .focusEffectDisabled()
            .help("模型参数")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .popover(item: popoverBinding(model: model), arrowEdge: .trailing) { focused in
            AIModelParametersPopover(
                model: focused,
                parameters: nonNullParametersBinding(for: focused),
                hasOverride: parametersBinding(focused).wrappedValue != nil,
                onReset: {
                    parametersBinding(focused).wrappedValue = nil
                }
            )
        }
    }

    /// 把 `popoverModel` 收窄成"只在等于本行 model 时为非 nil"的 Binding——这样
    /// `.popover(item:)` 只挂在该 model 对应的行上，不会被同列表内别的行复用。
    private func popoverBinding(model: AIModelDescriptor) -> Binding<AIModelDescriptor?> {
        Binding(
            get: { popoverModel?.id == model.id ? popoverModel : nil },
            set: { newValue in
                popoverModel = newValue
            }
        )
    }

    /// 把 nullable 的 `Binding<AIModelParameters?>` 提升成 popover 需要的非空
    /// `Binding<AIModelParameters>`：getter 在 nil 时返回 capability 默认（不写回），
    /// setter 写入时立即把 descriptor.parameters materialize 为非 nil。这样
    /// 用户**首次打开 popover 不会污染数据**——只有真正调整某个滑块/输入框
    /// 才会把这份覆盖落库。
    private func nonNullParametersBinding(for model: AIModelDescriptor) -> Binding<AIModelParameters> {
        let nullable = parametersBinding(model)
        return Binding(
            get: { nullable.wrappedValue ?? AIModelParameters.defaults(for: model.capability) },
            set: { nullable.wrappedValue = $0 }
        )
    }
}
