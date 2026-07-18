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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.vertical, 8)
            Divider()
            searchField
                .padding(.vertical, 8)
            Divider()
            modelScroll
                .padding(.top, 8)
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack {
            // HOM-203：避免 `Text("key \(count)")` 被编译成空壳 `%@` entry，运行时回退成 key 字面量。
            Text(String(
                format: String.l10n("settings.ai.modelList.totalFormat"),
                profile.models.count
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(String(
                    format: String.l10n("settings.ai.modelList.matchedFormat"),
                    filteredModels.count
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var searchField: some View {
        TextField("settings.ai.modelList.searchPlaceholder", text: $query)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
    }

    private var modelScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredModels.isEmpty {
                    Text("settings.ai.modelList.empty")
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
        .frame(height: modelScrollHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
    }

    /// HOM-126 follow-up (dong4j 反馈 2026-06-07，截图：2 个模型 → 列表底部留大片空白)：
    /// 列表高度自适应——按当前可见行数算出实际所需高度，行数不超过 4 时正好贴合内容、
    /// 不留空白；超过 4 时锁定为 4 行高度并出现滚动。
    ///
    /// 行高估算：modelRow 默认是双行 label（name + owner）
    ///   - Text(name) body ≈ 13pt
    ///   - Text(owner) caption ≈ 11pt
    ///   - VStack spacing 2pt
    ///   - .padding(.vertical, 7) 上下各 7pt = 14pt
    ///   - 单行 row 高度 ≈ 13 + 2 + 11 + 14 ≈ 40pt
    /// 加上行间 Divider 1pt 和少量缓冲，取 `perRowHeight = 44pt`，能稳定容纳"双行 label"
    /// 不被裁切；单行 label（无 owner）row 会稍显富余，但视觉留白与双行 row 协调。
    private var modelScrollHeight: CGFloat {
        // 空状态（无匹配）也给一行高度，避免折叠成 0 让 ScrollView 完全消失
        let visibleRows = filteredModels.isEmpty ? 1 : min(filteredModels.count, 4)
        let perRowHeight: CGFloat = 44
        let dividerHeight: CGFloat = 1
        return CGFloat(visibleRows) * perRowHeight + CGFloat(max(0, visibleRows - 1)) * dividerHeight
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
            // (docs/3-设计/详细设计/07-UI交互设计.md §1.2)——所有 .buttonStyle(.plain) 必
            // 须紧跟 .focusEffectDisabled() 抑制 macOS 15+ 默认蓝色 focus ring。
            .focusEffectDisabled()
            .help("settings.ai.modelList.parametersHelp")
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
            .appLocaleEnvironment()
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
