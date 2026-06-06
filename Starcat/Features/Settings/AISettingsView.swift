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
    @State private var promptTask: AIModelTask = .summary

    /// HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
    /// "默认设置"（原"模型设置"）也改成 tab 样式，4 个任务（summary/tags/
    /// embedding/translation）共用一行 Provider+模型 picker。和 parameterTask /
    /// promptTask 分开，让用户在不同区切换任务时互不干扰（设默认时看的是
    /// summary，但调参数时可能在调 tags，强同步会反直觉）。
    @State private var taskModelTask: AIModelTask = .summary

    // HOM-68 follow-up v2 (2026-06-05 22:30 dong4j 反馈)：
    // Prompt 不是首次配置必填项，默认收起来减小视觉噪音，需要时再展开。
    // 用 SceneStorage 而不是 @State，让用户的展开偏好跨设置页打开持久化，
    // 但保持"应用首次启动默认折叠"语义。
    //
    // HOM-68 follow-up v9：原"模型参数"区已迁到"已发现模型"每行的齿轮 popover
    // （模型粒度，不再按任务），不再需要 isParametersExpanded SceneStorage。
    @SceneStorage("settings.ai.prompt.expanded") private var isPromptExpanded: Bool = false

    // HOM-68 follow-up v7：把"已发现模型" / "默认设置" 也变成可折叠，
    // 与"模型参数" / "Prompt" 折叠风格统一。默认折叠以减小首次进入设置页的
    // 视觉噪音。"已发现模型" 在用户点击"测试并获取模型"且成功获取到 ≥1 个
    // 模型时自动展开（见 `testAndFetchModels`），这样新用户走"配置 → 测试 →
    // 选模型"完整路径时不需要手动展开折叠组。
    @SceneStorage("settings.ai.discoveredModels.expanded") private var isDiscoveredModelsExpanded: Bool = false
    @SceneStorage("settings.ai.taskModels.expanded") private var isTaskModelsExpanded: Bool = false

    var body: some View {
        // HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
        // 删除独立的"模型参数"区。原因：参数与"任务"绑定有歧义——同一模型被
        // 摘要 / 标签 / 翻译复用时，按任务调参数会出现"在'模型参数 → 摘要'调
        // temperature 只对'用 X 模型的摘要任务'生效，其它任务用 X 模型还是默认值"
        // 的反直觉行为。改成每行模型一个齿轮按钮 + popover，参数与"模型"绑定。
        Form {
            providerSection
            enabledModelsSection
            taskModelsSection
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
                // HOM-AIPROVIDERS-2026-06-06：服务商配置 picker 在每个 profile 行
                // 前面挂当前 provider 的 logo，让用户在多 profile（"OpenAI 摘要 +
                // DeepSeek 翻译 + Ollama embedding"）场景下一眼分辨。
                // SwiftUI Picker 的 menu style 会把 Label 内的 Image 一起渲染到下拉
                // 菜单和已选 caption 区，无需为下拉 / 当前选中分别画。
                Picker("服务商配置", selection: selectedProfileBinding) {
                    ForEach(settings.aiProviderProfiles) { profile in
                        Label {
                            Text(profile.displayName)
                        } icon: {
                            AIProviderIconView(provider: profile.provider, size: 14)
                        }
                        .tag(Optional(profile.id))
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
                // HOM-AIPROVIDERS-2026-06-06：Provider picker（"切换底层服务商类型"）
                // 列表里每一项都带 logo + 本地化名称，便于在 23 种服务商之间快速识别。
                // 注意 displayName 是 LocalizedStringKey，所以 Label 的 title 直接传它，
                // SwiftUI 会按当前 locale 自动解析；中文服务商（豆包/混元/通义/智谱/硅基）
                // 走 `ai.provider.*` xcstrings key，英文服务商保留 String literal 原名。
                Picker("Provider", selection: profileProviderBinding(profile.id)) {
                    ForEach(AIServiceProvider.allCases) { provider in
                        Label {
                            Text(provider.displayName)
                        } icon: {
                            AIProviderIconView(provider: provider, size: 14)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.menu)

                // HOM-AIPROVIDERS-2026-06-06 layout follow-up v3（dong4j 第三次反馈
                // "现在还是没看到输入框变长,而且 baseURL 超长的时候还会换行显示"）：
                //
                // 根因(看 Cloudflare 那张截图发现的)：
                // 前一版用 `LabeledContent("xxx") { TextField... }` 仍然换行——因为
                // **`LabeledContent` 在 macOS 15 `.formStyle(.grouped)` 下是 responsive 的**,
                // 当 control 自身内容(如 Cloudflare 的 `{YOUR_ACCOUNT_ID}` 占位 URL)宽度
                // 超过 row 可用宽度时,SwiftUI 会自动把 label 拉到上面、control 撑满
                // 整行(竖排 fallback)。这是 SwiftUI 内置行为,加 `.frame(maxWidth:.infinity)`
                // 都拦不住——`.frame` 只影响最小/最大尺寸申请,不能阻止 responsive layout 切换。
                //
                // 唯一可靠的解法:**完全弃用 LabeledContent,用 HStack 手控 label 宽度**。
                // HStack 是死板的横向容器,内部子 view 不会因为容器宽度不足而切换布局,
                // 只会按 layout priority 压缩;给 label 固定 130pt(目测与上面 Picker
                // 行 LabeledContent 自动算出的 label 列宽度对齐),TextField `.frame(maxWidth:
                // .infinity)` 撑满剩余宽度;长 URL 自然走 NSTextField 默认的"字段内
                // 横向滚动"——光标处可见,字段右边缘外被裁掉,永远不会撑高整行也不会
                // 把 layout 切成竖排。
                //
                // 抽 `inlineLongInputRow(label:field:)` helper 是为了把这套模式收口——
                // 后续任何"label + 长内容输入"的行都用它,不允许直接写 LabeledContent。
                inlineLongInputRow(label: "显示名称") {
                    TextField("", text: profileTextBinding(profile.id, keyPath: \.displayName))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                }

                inlineLongInputRow(label: "Base URL") {
                    TextField("", text: profileTextBinding(profile.id, keyPath: \.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .disableAutocorrection(true)
                        .textContentType(.URL)
                }

                inlineLongInputRow(label: "API Key") {
                    SecureField(profile.provider.allowsEmptyAPIKey ? "本地服务可留空" : "", text: apiKeyBinding(profile.id))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                }

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
                            capabilityBinding: { model in modelCapabilityBinding(profile.id, model.id) },
                            parametersBinding: { model in modelParametersBinding(profile.id, model.id) }
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
        // HOM-68 follow-up v7：tab 样式（segmented Picker + 单行 Provider/模型/自定义），
        // 与"模型参数" / "Prompt" 一致；DisclosureGroup 默认折叠。
        // HOM-68 follow-up v8：标题从"默认设置"改成"模型配置"。
        // HOM-68 follow-up v10 (dong4j 反馈 2026-06-05 23:55)：tab 与下面的
        // Provider/模型/自定义 行原本只隔默认 VStack 间距（≈ 4pt），视觉黏连。
        // 用 VStack(spacing: 14) 显式给开 14pt，与 Prompt 区"任务行 → System
        // Prompt 标签"的呼吸感对齐，让 tab 切换后"现在配的是哪个任务"边界清晰。
        Section {
            DisclosureGroup(isExpanded: $isTaskModelsExpanded) {
                VStack(spacing: 14) {
                    Picker("任务", selection: $taskModelTask) {
                        ForEach(AIModelTask.allCases) { task in
                            Text(task.displayName).tag(task)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    taskModelRow(taskModelTask)
                }
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
        // HOM-68 follow-up v8：删行首 `Text(task.displayName)`——外层 segmented
        // tab 已经在显示当前任务名，再写一次是冗余。
        //
        // HOM-68 follow-up v13 (dong4j 反馈 2026-06-06 00:43)：
        // 1. Provider picker 加 `.labelsHidden()` 去掉行首"Provider"文字。该
        //    标签冗余——外层 tab 已说明这是哪个任务的配置，第一个 picker 是
        //    Provider 不言自明。保留"模型"label，作为两个 picker 之间的视觉
        //    分隔标识（用户明确只点名"Provider"要删，模型不动）；
        // 2. "自定义" 改 `.fixedSize()` 只占 intrinsic 宽度，并放在 HStack 末尾
        //    （无 trailing Spacer），自然右对齐——为 Provider / 模型 两个下拉
        //    腾出最大水平空间，避免长 Provider/模型名被截断成"De..." / "deeps..."。
        let currentProviderID = taskConfig(task).providerID
        let availableModels = enabledModels(
            providerID: currentProviderID,
            capability: task.requiredCapability
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // HOM-AIPROVIDERS-2026-06-06：任务 → provider picker 同样给每一项
                // 挂上 provider logo，使用户在切换"摘要走哪个服务"、"翻译走哪个服务"
                // 时不需要靠 displayName 区分（部分 profile 名是用户自定义的，可能与
                // 实际底层服务商不一致，logo 比文字更可靠）。
                Picker("Provider", selection: taskProviderBinding(task)) {
                    ForEach(settings.aiProviderProfiles.filter(\.isEnabled)) { profile in
                        Label {
                            Text(profile.displayName)
                        } icon: {
                            AIProviderIconView(provider: profile.provider, size: 14)
                        }
                        .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
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

                Toggle("自定义", isOn: taskCustomEnabledBinding(task))
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }

            if taskConfig(task).useCustomModel {
                TextField("自定义模型名", text: taskCustomModelBinding(task))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
        }
    }

    // MARK: - Parameters (已迁移到 AIModelListView 的齿轮 popover)

    // HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
    // 原本独立的 `parametersSection`（按任务调 Temperature/Top P/Top K/MaxToken/
    // Timeout/Stream）已删除。参数现在与"模型"绑定，编辑入口在"已发现模型"列表
    // 每行最右侧的齿轮按钮 → popover（`AIModelParametersPopover`）。
    //
    // 删除的辅助函数：parametersSection / parameterSlider / parameterIntField /
    // parameterDoubleBinding / parameterIntBinding / parameterBoolBinding /
    // parameterMaxTokensKBinding / parameterTimeoutSecondsBinding——这些都是
    // "task → AIModelParameters" 路径上的辅助，迁移后 popover 内部自带等价控件。

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
    /// 长内容输入行的标准布局：label 左、TextField 右、强制水平、TextField 占满
    /// label 后所有空间、长内容字段内横向截断不换行。
    ///
    /// 为什么不用 `LabeledContent`(dong4j 2026-06-06 连续三次截图反馈才搞清楚)：
    /// macOS 15 `.formStyle(.grouped)` 下,`LabeledContent` 是 **responsive** 的——
    /// 当 control 内容宽度超过 row 可用宽度时,SwiftUI 自动把 layout 切成"label 上、
    /// control 下"的竖排,即使在 control 上加 `.frame(maxWidth: .infinity)` 也拦不住
    /// (`.frame` 只影响最小/最大尺寸申请,不能阻止 layout 切换)。Cloudflare 的
    /// `{YOUR_ACCOUNT_ID}` 占位 URL 是典型触发点。
    ///
    /// HStack 是**死板**的横向容器,不会自动切布局,只按 layout priority 压缩。
    /// 配合"label 固定 130pt + TextField `.frame(maxWidth: .infinity)`"组合,效果：
    /// - label 始终在左,宽度恒定 130pt(与上面 Picker 行的 LabeledContent 自动列宽
    ///   目测对齐,视觉一致)
    /// - TextField 撑满 label 后所有剩余宽度
    /// - 长 URL 走 NSTextField 默认的"字段内横向滚动"——光标处可见,超出右边缘的
    ///   字符被裁掉,永远不撑高整行,永远不竖排
    ///
    /// 130pt 是经验值:目测能容纳"服务商配置"(4 个中文字符 ≈ 64pt)、"Base URL"
    /// (8 个英文字符 ≈ 80pt)、"显示名称"(4 中文 ≈ 64pt)三个标签 + 一定富余。
    /// 未来若需要更长的 label(如"OAuth Redirect URI"),提升此常量或抽成参数。
    @ViewBuilder
    private func inlineLongInputRow<Field: View>(
        label: LocalizedStringKey,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            field()
                .frame(maxWidth: .infinity)
        }
    }

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
        // HOM-68 follow-up v10 (dong4j 反馈 2026-06-05 23:55)：项目强制规则
        // (docs/详细设计/07-UI交互设计.md §1.2 + CLAUDE.md §UI Focus Ring)——
        // 所有 .buttonStyle(.plain) Button 必须紧跟 .focusEffectDisabled()，否则
        // macOS 15+ 会在聚焦时套一个蓝色 focus ring，与项目暗色面板视觉冲突。
        .focusEffectDisabled()
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

    /// HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
    /// 模型粒度参数 binding。包给 `AIModelListView` 让齿轮按钮 popover 写回。
    /// 返回的是可空 binding——`nil` 表示"未覆盖，走 capability 默认"，popover
    /// 内部会在第一次实际改值时把它 materialize 成非 nil 值。
    private func modelParametersBinding(_ profileID: String, _ modelID: String) -> Binding<AIModelParameters?> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.parameters },
            set: { newParameters in
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.parameters = newParameters
                }
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
