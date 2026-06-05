//
//  AISettingsView.swift
//  Starcat
//
//  AI 服务配置面板。
//
//  模块级说明：
//  - 本页面实现多服务商 BYOK：用户可以同时配置 OpenAI、DeepSeek、OpenRouter、
//    Ollama、LM Studio 或任意 OpenAI-compatible 服务。
//  - API Key 按 provider profile ID 写入 `KeychainManager` 管理的本地加密文件；
//    provider / 模型启用状态 / 参数 / Prompt 写入 `AppSettings`。
//  - 摘要、推荐标签、Embedding 三类任务独立选择 provider 与模型，满足“摘要走本地，
//    Embedding 走远端”这类组合。
//
//  关键约束：
//  - 不把 API Key 存入 UserDefaults，也不打印到日志。
//  - 模型列表接口只强依赖 `id` 字段，能力用启发式推断并允许用户手动修正。
//  - `topK` 当前仅保存配置，不发送到标准 OpenAI Chat Completions，原因见详细设计文档。
//

import SwiftUI

/// AI 设置 Tab 页面。
struct AISettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var selectedProfileID: String?
    @State private var apiKeys: [String: String] = [:]
    @State private var isTestingProfileID: String?
    @State private var keyError: String?
    @State private var parameterTask: AIModelTask = .summary
    @State private var promptTask: AIModelTask = .summary

    /// HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
    /// "默认设置"（原"模型设置"）也改成 tab 样式，4 个任务（summary/tags/
    /// embedding/translation）共用一行 Provider+模型 picker。和 parameterTask /
    /// promptTask 分开，让用户在不同区切换任务时互不干扰（设默认时看的是
    /// summary，但调参数时可能在调 tags，强同步会反直觉）。
    @State private var taskModelTask: AIModelTask = .summary

    // HOM-68 follow-up v2 (2026-06-05 22:30 dong4j 反馈)：
    // 模型参数 / Prompt 不是首次配置必填项，默认收起来减小视觉噪音，需要时再展开。
    // 用 SceneStorage 而不是 @State，让用户的展开偏好跨设置页打开持久化，
    // 但保持"应用首次启动默认折叠"语义。
    @SceneStorage("settings.ai.parameters.expanded") private var isParametersExpanded: Bool = false
    @SceneStorage("settings.ai.prompt.expanded") private var isPromptExpanded: Bool = false

    // HOM-68 follow-up v7：把"已发现模型" / "默认设置" 也变成可折叠，
    // 与"模型参数" / "Prompt" 折叠风格统一。默认折叠以减小首次进入设置页的
    // 视觉噪音。"已发现模型" 在用户点击"测试并获取模型"且成功获取到 ≥1 个
    // 模型时自动展开（见 `testAndFetchModels`），这样新用户走"配置 → 测试 →
    // 选模型"完整路径时不需要手动展开折叠组。
    @SceneStorage("settings.ai.discoveredModels.expanded") private var isDiscoveredModelsExpanded: Bool = false
    @SceneStorage("settings.ai.taskModels.expanded") private var isTaskModelsExpanded: Bool = false

    var body: some View {
        Form {
            providerSection
            enabledModelsSection
            taskModelsSection
            parametersSection
            promptSection
            privacySection
        }
        .formStyle(.grouped)
        .task {
            ensureSelection()
            loadAPIKeys()
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            // HOM-68 follow-up v2 (dong4j 反馈 #1)：
            // "新增服务商" / "删除当前" 按钮移到 picker 同一行的右侧，
            // 紧凑且符合设置面板"次要操作贴近主控件"的常见 macOS 布局。
            HStack {
                Picker("服务商配置", selection: selectedProfileBinding) {
                    ForEach(settings.aiProviderProfiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.menu)

                Spacer(minLength: 12)

                Button {
                    addProfile()
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .help("新增服务商")

                Button(role: .destructive) {
                    deleteSelectedProfile()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .help("删除当前服务商")
                .disabled(settings.aiProviderProfiles.count <= 1)
            }

            if let profile = selectedProfile {
                Picker("Provider", selection: profileProviderBinding(profile.id)) {
                    ForEach(AIServiceProvider.allCases) { provider in
                        Text(provider.defaultProfileName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                TextField("显示名称", text: profileTextBinding(profile.id, keyPath: \.displayName))
                    .textFieldStyle(.roundedBorder)

                TextField("Base URL", text: profileTextBinding(profile.id, keyPath: \.baseURL))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                SecureField(profile.provider.allowsEmptyAPIKey ? "API Key（本地服务可留空）" : "API Key", text: apiKeyBinding(profile.id))
                    .textFieldStyle(.roundedBorder)

                // HOM-68 follow-up v2 (dong4j 反馈 #2)：
                // 状态提示（测试成功/失败/未测试）在左侧，"保存 Key" / "测试并获取模型"
                // 两个按钮在右侧。这样阅读顺序与"看到提示 → 决定操作"的认知顺序一致，
                // 且操作按钮聚成一组更容易点击。
                HStack {
                    Text(profile.lastTestStatus.displayText)
                        .font(.caption)
                        .foregroundStyle(statusTint(profile.lastTestStatus))
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer(minLength: 12)

                    Button {
                        saveAPIKey(profileID: profile.id)
                    } label: {
                        Label("保存 Key", systemImage: "key.fill")
                    }

                    Button {
                        Task { await testAndFetchModels(profile) }
                    } label: {
                        if isTestingProfileID == profile.id {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("测试并获取模型")
                            }
                        } else {
                            Label("测试并获取模型", systemImage: "network")
                        }
                    }
                    .disabled(isTestingProfileID != nil || (!profile.provider.allowsEmptyAPIKey && apiKeys[profile.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }

                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("AI 服务商")
        } footer: {
            Text("测试会调用模型列表接口；如果服务商返回的模型能力不完整，可在下方手动修正 Chat / Embedding 类型。")
        }
    }

    private var enabledModelsSection: some View {
        // HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
        // 改成 DisclosureGroup 默认折叠，与"模型参数" / "Prompt" 折叠风格统一。
        // 自动展开时机：用户点"测试并获取模型"成功且 ≥1 个模型时，自动 expand
        // 一次（见 `testAndFetchModels`），让"配置 → 测试 → 看模型"的完整路径
        // 不需要手动展开折叠组。
        Section {
            DisclosureGroup(isExpanded: $isDiscoveredModelsExpanded) {
                if let profile = selectedProfile {
                    if profile.models.isEmpty {
                        Text("暂无模型。点击“测试并获取模型”，或在默认设置中使用自定义模型名。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        AIModelListView(
                            profile: profile,
                            enabledBinding: { model in modelEnabledBinding(profile.id, model.id) },
                            capabilityBinding: { model in modelCapabilityBinding(profile.id, model.id) }
                        )
                    }
                }
            } label: {
                disclosureLabel("已发现模型", isExpanded: $isDiscoveredModelsExpanded)
            }
        }
    }

    // MARK: - Tasks

    private var taskModelsSection: some View {
        // HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
        // 之前 4 个任务竖向铺开 4 行，每行重复 "Provider + 模型 + 自定义" 三件套，
        // 占整页 1/3 高度。改成 tab 样式（与"模型参数" / "Prompt" 一致）：
        //   1. 顶部 segmented Picker 选任务（summary / tags / embedding / translation）；
        //   2. 下面只渲染当前选中任务那一行；
        //   3. 整段 DisclosureGroup 默认折叠。
        //
        // 标题改"默认设置"——这里配置的是"每类任务默认用哪个 provider 的哪个模型"，
        // 与"已发现模型"区（模型清单 + chat/embedding 能力标注）职责分离。
        Section {
            DisclosureGroup(isExpanded: $isTaskModelsExpanded) {
                Picker("任务", selection: $taskModelTask) {
                    ForEach(AIModelTask.allCases) { task in
                        Text(task.displayName).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                taskModelRow(taskModelTask)
            } label: {
                disclosureLabel("模型配置", isExpanded: $isTaskModelsExpanded)
            }
        }
    }

    private func taskModelRow(_ task: AIModelTask) -> some View {
        // HOM-68 follow-up v3：模型下拉只列**当前选中 provider** 的模型，
        // 消除跨 provider 同名模型同时勾选的 bug；provider 切换由
        // `taskProviderBinding` setter 自动把 modelID 重置为新 provider 的第一个
        // 匹配能力的模型。
        //
        // HOM-68 follow-up v8 (dong4j 反馈 2026-06-05 23:30)：
        // 1. 删行首 `Text(task.displayName)`——外层 segmented tab 已经在显示
        //    当前任务名，再写一次是冗余；
        // 2. Provider / 模型 / 自定义 改 `.frame(maxWidth: .infinity)` 三等分。
        //    之前 Provider 固定 180pt、模型 picker 吃剩下大头、Toggle 极窄，
        //    视觉非常碎。1/3 + 1/3 + 1/3 形成稳定栅格。
        let currentProviderID = taskConfig(task).providerID
        let availableModels = enabledModels(
            providerID: currentProviderID,
            capability: task.requiredCapability
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Provider", selection: taskProviderBinding(task)) {
                    ForEach(settings.aiProviderProfiles.filter(\.isEnabled)) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Picker("模型", selection: taskModelBinding(task)) {
                    if availableModels.isEmpty {
                        Text("（无可用模型，请测试并获取模型，或勾选「自定义」）")
                            .tag("")
                    } else {
                        ForEach(availableModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                // Toggle intrinsic 宽度很窄；HStack + 末尾 Spacer 把 1/3 列撑开，
                // checkbox 左对齐到自己 1/3 区域开头，与 Provider/模型 picker 形
                // 成同步左缘的三栏栅格。
                HStack {
                    Toggle("自定义", isOn: taskCustomEnabledBinding(task))
                        .toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }

            if taskConfig(task).useCustomModel {
                TextField("自定义模型名", text: taskCustomModelBinding(task))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
        }
    }

    // MARK: - Parameters

    /// HOM-68 follow-up v3 (dong4j 反馈 2026-06-05 22:40)：
    /// 任务 picker 之前与 "Temperature/Top P/..." 同列在 DisclosureGroup 里，
    /// `pickerStyle(.segmented)` 自带的"任务"label 会占掉一段固定宽度，加上
    /// DisclosureGroup 的左侧缩进，4 个任务按钮容易被挤到只剩两字符宽度（截图）。
    /// 改法：
    ///   1. 任务 picker `.labelsHidden()`，去掉左侧 "任务" label；
    ///   2. `.frame(maxWidth: .infinity)` 让 picker 占满折叠组的可用宽度；
    ///   3. Top K / 最大 Token / 超时时间 由 Stepper 改 TextField（带 NumberFormatter
    ///      + 阈值钳制），用户可以直接键入数字，不再点 100 次 Stepper；
    ///   4. "最大 Token" 单位换成 K（内部仍存原始 token 数），默认 128 K；
    ///   5. 删除底部 "Top K 不是 OpenAI..." 备注——保留在代码注释里给开发者看就够了。
    ///
    /// 实现注记：Top K 在 OpenAI Chat Completions 不是标准字段，当前 AIClient 仅
    /// 把它保存到配置里，未来对接 LM Studio / Ollama 原生 API 时再发送。
    private var parametersSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isParametersExpanded) {
                Picker("任务", selection: $parameterTask) {
                    ForEach(AIModelTask.allCases) { task in
                        Text(task.displayName).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                let isEmbedding = parameterTask == .embedding
                parameterSlider("Temperature", value: parameterDoubleBinding(parameterTask, \.temperature), range: 0...2, disabled: isEmbedding)
                parameterSlider("Top P", value: parameterDoubleBinding(parameterTask, \.topP), range: 0...1, disabled: isEmbedding)

                parameterIntField(
                    "Top K",
                    binding: parameterIntBinding(parameterTask, \.topK),
                    range: 0...500,
                    unit: nil,
                    disabled: isEmbedding
                )
                parameterIntField(
                    "最大 Token",
                    binding: parameterMaxTokensKBinding(parameterTask),
                    range: 1...512,
                    unit: "K",
                    disabled: isEmbedding
                )
                parameterIntField(
                    "超时时间",
                    binding: parameterTimeoutSecondsBinding(parameterTask),
                    range: 30...3_600,
                    unit: "秒",
                    disabled: false
                )

                // HOM-68 follow-up v6 (dong4j 反馈 2026-06-05 23:10)：
                // 之前 Toggle 占满整行，开关控件在行的最右边——比 TextField
                // 多出 44pt 单位列宽度，跟上面 5 行参数对不齐。改成手动 HStack：
                // 文字 label 左对齐，Spacer 把开关推到右侧，最后塞 44pt Color.clear
                // 把开关左移 44pt，让开关右边缘对齐 TextField 右边缘。
                HStack {
                    Text("优先使用流式响应")
                    Spacer(minLength: 8)
                    Toggle("", isOn: parameterBoolBinding(parameterTask, \.streamEnabled))
                        .labelsHidden()
                        .disabled(parameterTask == .embedding || parameterTask == .tags)
                    Color.clear.frame(width: 44)
                }
            } label: {
                disclosureLabel("模型参数", isExpanded: $isParametersExpanded)
            }
        }
    }

    /// HOM-68 follow-up v5 (dong4j 反馈 2026-06-05 23:00)：
    /// v4 用 `Text + onTapGesture` 不生效——SwiftUI 在 `Form(.grouped)` 里给
    /// `DisclosureGroup` label 套了一层非交互容器，会吞掉 `onTapGesture`，
    /// 只有 chevron 内置的 hit area 才能触发。
    ///
    /// 改用 `Button(action:) + .buttonStyle(.plain)`：Button 在 Form 里是
    /// SwiftUI 一等公民，永远拿到点击事件；plain style 抹掉默认按钮装饰，
    /// 视觉上仍是普通标题文字。
    ///
    /// 用 withAnimation 让展开/折叠跟 chevron 旋转走同一条动画曲线，避免"点
    /// 标题瞬切、点 chevron 平滑"的不一致体感。
    private func disclosureLabel(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func parameterSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        disabled: Bool
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
                .disabled(disabled)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// 整数参数输入行：90pt 标题列 + 中段 TextField 占满（与 Slider 同宽）+ 44pt 单位列。
    ///
    /// HOM-68 follow-up v5 (dong4j 反馈 2026-06-05 23:00)：之前 TextField 固定
    /// 90pt 靠右，比同一组里的 Slider 短一大截，竖向看像断行。改为 TextField
    /// 不指定 width 让它吃满中段（与 Slider 同样的"中段填充"行为），右侧 44pt
    /// 单位列与 Slider 的"当前值"列对齐，三种参数（Top K / Token / 超时）从此
    /// 与 Temperature / Top P 在视觉上形成统一栅格。
    ///
    /// 钳制策略：值只在用户提交（失焦 / 回车）时才写回 binding，写回时再做
    /// `clamp(into: range)`。这样在键入过程中不会出现"输入到 12 就立刻变成 100"
    /// 的反人类体验。
    private func parameterIntField(
        _ title: String,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String?,
        disabled: Bool
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            TextField(
                "",
                value: Binding(
                    get: { binding.wrappedValue },
                    set: { newValue in
                        binding.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
                    }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .disabled(disabled)
            if let unit {
                // HOM-68 follow-up v6 (dong4j 反馈 2026-06-05 23:10)：
                // 单位列改右对齐——之前 `.leading` 时 "K" / "秒" 这种 1-2 字符
                // 会贴在 44pt 列的左边、距离右边缘还有一大段空白，竖向看 3 个
                // 单位不在一条线上，对齐感差。改 `.trailing` 后 "K" / "秒" 都
                // 紧贴右边缘，竖向形成统一的对齐线。
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                // 占位与有单位行对齐，避免输入框宽度跳变（同 Slider 行右侧 44pt 值列）。
                Color.clear.frame(width: 44)
            }
        }
    }

    // MARK: - Prompt

    /// HOM-68 follow-up v3 (dong4j 反馈 2026-06-05 22:40)：
    /// - 任务 picker + "恢复默认" 之前同行抢宽度，picker 被挤；改成 picker
    ///   `.labelsHidden().frame(maxWidth: .infinity)` 优先吃满宽度，按钮固定
    ///   尺寸跟在右边；
    /// - "User Prompt Template" 改名 "User Prompt"，与 "System Prompt" 对齐
    ///   命名；两个标题用 `.frame(maxWidth: .infinity, alignment: .leading)`
    ///   显式左对齐，避免 Form grouped 样式把它居中显示；
    /// - 两个 TextEditor 改为固定高度（System 100 / User 160），TextEditor 在
    ///   macOS 上内置垂直滚动，超出高度自动出现滚动条，不再让长 prompt 撑大
    ///   整个设置面板。
    private var promptSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isPromptExpanded) {
                HStack(spacing: 12) {
                    Picker("任务", selection: $promptTask) {
                        ForEach([AIModelTask.summary, .tags, .translation]) { task in
                            Text(task.displayName).tag(task)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button {
                        restoreDefaultPrompt(promptTask)
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("恢复 \(promptTask.displayName) 的默认 Prompt")
                    .fixedSize()
                }

                Text("System Prompt")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: promptSystemBinding(promptTask))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )

                Text("User Prompt")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextEditor(text: promptUserBinding(promptTask))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )

                Text(promptPlaceholderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                disclosureLabel("Prompt", isExpanded: $isPromptExpanded)
            }
        }
    }

    /// 当前任务的占位符提示文案。
    /// - summary / tags：仅 `{context}` 表示仓库元数据 + README 摘要；
    /// - translation：额外支持 `{targetLanguage}` 表示当前目标语言名（如 `Simplified Chinese`）。
    private var promptPlaceholderHint: String {
        switch promptTask {
        case .summary, .tags:
            return "User Prompt 中的 {context} 会在运行时替换为仓库元数据和 README 摘要。"
        case .translation:
            return "支持两个占位符：{targetLanguage} 替换为当前目标语言名（如 Simplified Chinese / English / Japanese），{context} 替换为源 README HTML 片段。"
        case .embedding:
            return ""
        }
    }

    private var privacySection: some View {
        Section {
            Label {
                Text("Starcat 不经过自建服务器转发 AI 请求。摘要、推荐标签和语义搜索会把必要的仓库元数据 / README 摘要发送给你选择的 Provider。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Actions

    private func ensureSelection() {
        if selectedProfileID == nil || settings.aiProviderProfiles.allSatisfy({ $0.id != selectedProfileID }) {
            selectedProfileID = settings.aiProviderProfiles.first?.id
        }
    }

    private func loadAPIKeys() {
        for profile in settings.aiProviderProfiles {
            apiKeys[profile.id] = (try? KeychainManager.shared.loadAIKey(forProvider: profile.id)) ?? ""
        }
    }

    private func saveAPIKey(profileID: String) {
        keyError = nil
        do {
            let trimmed = apiKeys[profileID, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try KeychainManager.shared.deleteAIKey(forProvider: profileID)
            } else {
                try KeychainManager.shared.storeAIKey(trimmed, forProvider: profileID)
                apiKeys[profileID] = trimmed
            }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func addProfile() {
        var profiles = settings.aiProviderProfiles
        let profile = AIProviderProfile(provider: .openAICompatible)
        profiles.append(profile)
        settings.aiProviderProfiles = profiles
        selectedProfileID = profile.id
        apiKeys[profile.id] = ""
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileID, settings.aiProviderProfiles.count > 1 else { return }
        settings.aiProviderProfiles.removeAll { $0.id == id }
        try? KeychainManager.shared.deleteAIKey(forProvider: id)
        apiKeys.removeValue(forKey: id)
        selectedProfileID = settings.aiProviderProfiles.first?.id
        repairTasksAfterProfileChange()
    }

    @MainActor
    private func testAndFetchModels(_ profile: AIProviderProfile) async {
        isTestingProfileID = profile.id
        keyError = nil
        defer { isTestingProfileID = nil }

        saveAPIKey(profileID: profile.id)
        do {
            let models = try await OpenAIClient(configuration: AIClientConfiguration(
                providerID: profile.id,
                provider: profile.provider,
                apiKey: apiKeys[profile.id, default: ""],
                baseURL: profile.baseURL,
                chatModel: profile.models.first(where: { $0.capability == .chat })?.name ?? profile.provider.defaultChatModel,
                embeddingModel: profile.models.first(where: { $0.capability == .embedding })?.name ?? profile.provider.defaultEmbeddingModel,
                timeoutInterval: 60
            )).listModels()

            updateProfile(profile.id) { current in
                let oldByName = Dictionary(uniqueKeysWithValues: current.models.map { ($0.name, $0) })
                current.models = models.map { incoming in
                    if var old = oldByName[incoming.name] {
                        old.ownedBy = incoming.ownedBy
                        if old.capability == .unknown {
                            old.capability = incoming.capability
                        }
                        return old
                    }
                    return incoming
                }
                current.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                current.lastTestStatus = .success(modelCount: current.models.count)
            }
            repairTasksAfterProfileChange()
            // HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
            // 测试成功且抓到 ≥1 个模型时，自动把"已发现模型"折叠组展开。
            // 用户路径："配置 provider → 点测试 → 看到模型列表" 一气呵成，
            // 不用手动去展开折叠组。withAnimation 与 disclosureLabel 的展开动画
            // 走同一条曲线（easeInOut 0.18），视觉一致。
            if !models.isEmpty {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isDiscoveredModelsExpanded = true
                }
            }
        } catch {
            updateProfile(profile.id) { current in
                current.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                current.lastTestStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func restoreDefaultPrompt(_ task: AIModelTask) {
        updateTask(task) { config in
            switch task {
            case .summary:
                config.prompt = AIDefaultPrompts.summary
            case .tags:
                config.prompt = AIDefaultPrompts.tags
            case .embedding:
                config.prompt = AIDefaultPrompts.embedding
            case .translation:
                // README 翻译的 Prompt 由 ReadmeTranslationService 按目标语言动态拼装，
                // 不读 task.prompt；这里仅为 switch 穷举性兜底，UI 已经把 translation
                // 从 Prompt 编辑区排除（见 promptSection）。
                config.prompt = AIDefaultPrompts.translation
            }
        }
    }

    // MARK: - Bindings

    private var selectedProfileBinding: Binding<String?> {
        Binding(
            get: { selectedProfileID },
            set: { selectedProfileID = $0 }
        )
    }

    private func apiKeyBinding(_ profileID: String) -> Binding<String> {
        Binding(
            get: { apiKeys[profileID, default: ""] },
            set: { apiKeys[profileID] = $0 }
        )
    }

    private func profileProviderBinding(_ profileID: String) -> Binding<AIServiceProvider> {
        Binding(
            get: { profile(profileID)?.provider ?? .openAICompatible },
            set: { provider in
                updateProfile(profileID) { profile in
                    profile.provider = provider
                    profile.displayName = provider.defaultProfileName
                    profile.baseURL = provider.defaultBaseURL
                    profile.lastTestStatus = .notTested
                }
            }
        )
    }

    private func profileTextBinding(
        _ profileID: String,
        keyPath: WritableKeyPath<AIProviderProfile, String>
    ) -> Binding<String> {
        Binding(
            get: { profile(profileID)?[keyPath: keyPath] ?? "" },
            set: { newValue in
                updateProfile(profileID) { profile in
                    profile[keyPath: keyPath] = newValue
                    profile.lastTestStatus = .notTested
                }
            }
        )
    }

    private func modelEnabledBinding(_ profileID: String, _ modelID: String) -> Binding<Bool> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.isEnabled ?? false },
            set: { enabled in
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.isEnabled = enabled
                }
                repairTasksAfterProfileChange()
            }
        )
    }

    private func modelCapabilityBinding(_ profileID: String, _ modelID: String) -> Binding<AIModelCapability> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.capability ?? .unknown },
            set: { capability in
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.capability = capability
                }
                repairTasksAfterProfileChange()
            }
        )
    }

    private func taskProviderBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).providerID },
            set: { providerID in
                updateTask(task) { config in
                    config.providerID = providerID
                    if let first = enabledModels(providerID: providerID, capability: task.requiredCapability).first {
                        config.modelID = first.name
                        config.customModelName = first.name
                        config.useCustomModel = false
                    }
                }
            }
        )
    }

    private func taskModelBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).modelID },
            set: { modelName in
                updateTask(task) { config in
                    config.modelID = modelName
                    config.customModelName = modelName
                    config.useCustomModel = false
                }
            }
        )
    }

    private func taskCustomEnabledBinding(_ task: AIModelTask) -> Binding<Bool> {
        Binding(
            get: { taskConfig(task).useCustomModel },
            set: { enabled in updateTask(task) { $0.useCustomModel = enabled } }
        )
    }

    private func taskCustomModelBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).customModelName },
            set: { value in updateTask(task) { $0.customModelName = value } }
        )
    }

    private func parameterDoubleBinding(
        _ task: AIModelTask,
        _ keyPath: WritableKeyPath<AIModelParameters, Double>
    ) -> Binding<Double> {
        Binding(
            get: { taskConfig(task).parameters[keyPath: keyPath] },
            set: { value in updateTask(task) { $0.parameters[keyPath: keyPath] = value } }
        )
    }

    private func parameterIntBinding(
        _ task: AIModelTask,
        _ keyPath: WritableKeyPath<AIModelParameters, Int>
    ) -> Binding<Int> {
        Binding(
            get: { taskConfig(task).parameters[keyPath: keyPath] },
            set: { value in updateTask(task) { $0.parameters[keyPath: keyPath] = value } }
        )
    }

    private func parameterBoolBinding(
        _ task: AIModelTask,
        _ keyPath: WritableKeyPath<AIModelParameters, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { taskConfig(task).parameters[keyPath: keyPath] },
            set: { value in updateTask(task) { $0.parameters[keyPath: keyPath] = value } }
        )
    }

    /// "最大 Token" 的 K 单位 binding：getter / setter 在 1024 倍数与原始 token 数之间转换。
    /// 之前 UI 直接显示 token 数（如 128000），现在按 K 显示（128），输入更直观。
    /// 内部仍以原始 token 数 persist，保证调 OpenAI / 通义千问等 API 时不需要换算。
    private func parameterMaxTokensKBinding(_ task: AIModelTask) -> Binding<Int> {
        Binding(
            get: {
                let tokens = taskConfig(task).parameters.maxCompletionTokens
                return max(0, tokens / 1024)
            },
            set: { kValue in
                updateTask(task) { $0.parameters.maxCompletionTokens = max(0, kValue) * 1024 }
            }
        )
    }

    /// 超时时间 binding：底层是 Double 秒，UI 整数秒输入。
    /// timeoutSeconds 历史上是 Double 是为了将来支持亚秒级（如 0.5s），但用户层面
    /// 只用整数秒，所以 binding 在两侧做 Int <-> Double 转换。
    private func parameterTimeoutSecondsBinding(_ task: AIModelTask) -> Binding<Int> {
        Binding(
            get: { Int(taskConfig(task).parameters.timeoutSeconds.rounded()) },
            set: { seconds in
                updateTask(task) { $0.parameters.timeoutSeconds = Double(max(0, seconds)) }
            }
        )
    }

    private func promptSystemBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).prompt.systemPrompt },
            set: { value in updateTask(task) { $0.prompt.systemPrompt = value } }
        )
    }

    private func promptUserBinding(_ task: AIModelTask) -> Binding<String> {
        Binding(
            get: { taskConfig(task).prompt.userPromptTemplate },
            set: { value in updateTask(task) { $0.prompt.userPromptTemplate = value } }
        )
    }

    // MARK: - State helpers

    private var selectedProfile: AIProviderProfile? {
        guard let selectedProfileID else { return settings.aiProviderProfiles.first }
        return profile(selectedProfileID)
    }

    private func profile(_ id: String) -> AIProviderProfile? {
        settings.aiProviderProfiles.first { $0.id == id }
    }

    private func model(profileID: String, modelID: String) -> AIModelDescriptor? {
        profile(profileID)?.models.first { $0.id == modelID }
    }

    private func updateProfile(_ id: String, mutate: (inout AIProviderProfile) -> Void) {
        var profiles = settings.aiProviderProfiles
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&profiles[index])
        settings.aiProviderProfiles = profiles
    }

    private func updateModel(
        profileID: String,
        modelID: String,
        mutate: (inout AIModelDescriptor) -> Void
    ) {
        updateProfile(profileID) { profile in
            guard let index = profile.models.firstIndex(where: { $0.id == modelID }) else { return }
            mutate(&profile.models[index])
        }
    }

    private func taskConfig(_ task: AIModelTask) -> AIModelTaskConfiguration {
        switch task {
        case .summary:     return settings.aiSummaryTask
        case .tags:        return settings.aiTagsTask
        case .embedding:   return settings.aiEmbeddingTask
        case .translation: return settings.aiTranslationTask
        }
    }

    private func updateTask(_ task: AIModelTask, mutate: (inout AIModelTaskConfiguration) -> Void) {
        var config = taskConfig(task)
        mutate(&config)
        switch task {
        case .summary:
            settings.aiSummaryTask = config
        case .tags:
            settings.aiTagsTask = config
        case .embedding:
            settings.aiEmbeddingTask = config
        case .translation:
            settings.aiTranslationTask = config
        }
    }

    // `groupedEnabledModels(for:)` 已删除：HOM-68 follow-up v3 把"任务 → 模型"下拉
    // 收紧到只列当前 provider 的模型（见 `taskModelRow`），消除跨 provider 同名模型
    // 同时选中的视觉 bug。
    private func enabledModels(providerID: String, capability: AIModelCapability) -> [AIModelDescriptor] {
        profile(providerID)?.models.filter {
            $0.isEnabled && ($0.capability == capability || $0.capability == .unknown)
        } ?? []
    }

    private func repairTasksAfterProfileChange() {
        for task in AIModelTask.allCases {
            let config = taskConfig(task)
            let models = enabledModels(providerID: config.providerID, capability: task.requiredCapability)
            if profile(config.providerID) == nil || (!config.useCustomModel && models.allSatisfy { $0.name != config.modelID }) {
                let fallbackProfile = settings.aiProviderProfiles.first
                updateTask(task) { updated in
                    updated.providerID = fallbackProfile?.id ?? ""
                    if let first = fallbackProfile.flatMap({ enabledModels(providerID: $0.id, capability: task.requiredCapability).first }) {
                        updated.modelID = first.name
                        updated.customModelName = first.name
                        updated.useCustomModel = false
                    }
                }
            }
        }
    }

    private func statusTint(_ status: AIProviderTestStatus) -> Color {
        switch status {
        case .notTested:
            return .secondary
        case .success:
            return .green
        case .failed:
            return .red
        }
    }
}

#Preview {
    AISettingsTab()
        .environment(AppSettings(defaults: .standard))
        .frame(width: 720, height: 860)
}
