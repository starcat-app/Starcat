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

import AppKit
import OSLog
import SwiftUI

/// AI 设置 Tab 页面。
struct AISettingsTab: View {

    @Environment(AppSettings.self) private var settings

    /// HOM-AIPROVIDERS-PERSIST-2026-06-06 (dong4j 反馈)：
    /// 之前用 `@State private var selectedProfileID: String?` 保存当前选中的服务商
    /// profile，关掉 Settings 窗口再打开就会被 SwiftUI 销毁重建，`selectedProfileID`
    /// 重置为 nil，`ensureSelection()` 强制把它落回 `verifiedProfiles.first`。
    /// 多 profile 场景（DeepSeek + OpenAI 都已验证、用户最后选的是 OpenAI）下，
    /// 用户每次进入 AI 设置都会被强行切回 DeepSeek（第一个），第二行 Provider
    /// picker 也跟着回到 DeepSeek，违反"进页面时显示当前选中的已配好服务商"诉求。
    ///
    /// 改成 `@AppStorage` 跨 Settings 窗口和 app 启动都持久化，空串当 nil 哨兵
    /// （`@AppStorage` 不直接支持 `String?`）。`ensureSelection()` 仍保留兜底逻辑：
    /// 持久化的 ID 在当前已验证列表里找不到（profile 被删 / 升级后改了 ID）时
    /// 降级到 `verifiedProfiles.first?.id`，避免"指向幽灵 profile"。
    @AppStorage("settings.ai.lastSelectedProfileID") private var lastSelectedProfileIDStorage: String = ""

    /// 当前选中的服务商 profile ID。空串持久化值视为 nil。
    /// 真正的写入入口走 `setSelectedProfileID(_:)`，避免散落的赋值绕过空串哨兵。
    private var selectedProfileID: String? {
        lastSelectedProfileIDStorage.isEmpty ? nil : lastSelectedProfileIDStorage
    }

    @State private var draftProfile: AIProviderProfile?
    @State private var draftAPIKey: String = ""
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
        // HOM-AIPROVIDERS-DRAFT-DISCARD-2026-06-06 (dong4j 反馈):
        // SwiftUI macOS Settings scene 关闭窗口后不一定销毁 view 树,
        // `@State` 的 `draftProfile` 会残留——用户点 "+" 号生成空草稿、
        // 没改没测就关闭 Settings,下次再开 Settings 仍看到这个空草稿,
        // 违反"未完成配置在关闭设置后不保存"原则。
        //
        // 修法:监听 `NSWindow.willCloseNotification`,在 Settings 窗口真正
        // 关闭时丢弃 draft 三件套(profile / API key / keyError)。
        // **不用 `.onDisappear`**:macOS TabView 切 Tab 时 onDisappear 触发
        // 行为不一致(macOS 15 实测可能误触发),会误清用户在 AI Tab 半改完
        // 切到 General Tab 又切回来时的输入。`NSWindow.willCloseNotification`
        // 只在窗口真正关闭时触发,切 Tab 不动 NSWindow 生命周期,精准。
        .background(SettingsWindowCloseListener {
            // 只清未通过测试的 draft;通过测试的 draft 在 testAndFetchModels
            // 成功路径里已被晋升为 verified profile 并把 draftProfile 置 nil,
            // 这里看到的 draftProfile != nil 全是"未完成"草稿。
            AppLog.ai.debug("[AISettings] SettingsWindowCloseListener.onClose fired draftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
            if draftProfile != nil {
                draftProfile = nil
                draftAPIKey = ""
                keyError = nil
            }
        })
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
                if verifiedProfiles.isEmpty {
                    Text("暂无已验证服务商")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("服务商配置", selection: selectedProfileBinding) {
                        ForEach(verifiedProfiles) { profile in
                            Label {
                                Text(profile.displayName)
                            } icon: {
                                AIProviderIconView(provider: profile.provider, size: 14)
                            }
                            .tag(Optional(profile.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                Spacer(minLength: 12)

                Button {
                    beginDraft(provider: .openAICompatible)
                } label: {
                    Label("新增", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("新增服务商")
                .disabled(draftProfile != nil)

                Button(role: .destructive) {
                    deleteSelectedProfile()
                } label: {
                    Label("删除", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("删除当前服务商")
                .disabled(selectedProfile == nil)
            }

            // 第二行展示 Starcat 当前支持的全部服务商。选择一个服务商不会立刻写入
            // `aiProviderProfiles`；它只会创建/更新草稿，测试通过后才晋升为正式配置。
            Picker("Provider", selection: supportedProviderBinding) {
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

            if let profile = activeProfile {
                providerInputRows(profile)

                HStack {
                    Text(profile.lastTestStatus.displayText)
                        .font(.caption)
                        .foregroundStyle(statusTint(profile.lastTestStatus))
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer(minLength: 12)

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
                    .disabled(isTestingProfileID != nil || !canTest(profile))
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
            Text("测试会调用模型列表接口；Ollama / LM Studio 等本地服务 API Key 可留空；如果服务商返回的模型能力不完整，可在下方手动修正 Chat / Embedding 类型。")
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
                    ForEach(verifiedProfiles) { profile in
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

    /// AI 服务商三个长输入项的自定义表格块。
    ///
    /// 这里不再让 `Form(.grouped)` 分别布局三条 `TextField` row。macOS 的 Form 会
    /// 对每个 row 单独测量，短文本输入框、长 URL 输入框、聚焦态输入框得到的
    /// proposed width 可能不同；单行内 `GeometryReader` 也只能读到该 row 自己的
    /// 宽度，无法保证三行一致。
    ///
    /// 把三行收进同一个 `VStack` 后，Form 只测量一次这个块；块内部固定 label 列宽，
    /// 右侧输入框吃满剩余宽度，三个输入框自然共享同一左边界和右边界。
    ///
    /// 输入控件不能用 SwiftUI 原生 `TextField`：在 macOS `Form(.grouped)` 里，超长
    /// Base URL 仍可能参与 row 测量并把布局顶成换行。这里用 AppKit `NSTextField`
    /// 包装，明确要求单行、不可换行、内容超出时在字段内横向滚动。
    @ViewBuilder
    private func providerInputRows(_ profile: AIProviderProfile) -> some View {
        let labelWidth: CGFloat = 96
        let columnSpacing: CGFloat = 14
        let rowHeight: CGFloat = 52

        VStack(spacing: 0) {
            providerInputRow(label: "显示名称", labelWidth: labelWidth, columnSpacing: columnSpacing, rowHeight: rowHeight) {
                ProviderSingleLineTextField(text: editableProfileTextBinding(keyPath: \.displayName))
                    .accessibilityLabel("显示名称")
            }
            Divider()
            providerInputRow(label: "Base URL", labelWidth: labelWidth, columnSpacing: columnSpacing, rowHeight: rowHeight) {
                ProviderSingleLineTextField(text: editableProfileTextBinding(keyPath: \.baseURL))
                    .accessibilityLabel("Base URL")
            }
            Divider()
            providerInputRow(label: "API Key", labelWidth: labelWidth, columnSpacing: columnSpacing, rowHeight: rowHeight) {
                ProviderSingleLineTextField(text: editableAPIKeyBinding(), isSecure: true)
                    .accessibilityLabel("API Key")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight * 3 + 2)
    }

    private func providerInputRow<Field: View>(
        label: LocalizedStringKey,
        labelWidth: CGFloat,
        columnSpacing: CGFloat,
        rowHeight: CGFloat,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: columnSpacing) {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)
            field()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
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

    /// 写入 `selectedProfileID` 的统一入口。
    /// nil → 持久化层写空串哨兵；非 nil → 直接写入 ID。
    /// 集中走这个 helper 是为了让"空串 ↔ nil"语义不要散落到 4 个赋值点。
    private func setSelectedProfileID(_ id: String?) {
        AppLog.ai.debug("[AISettings] setSelectedProfileID(\(id ?? "nil", privacy: .public)) prev=\(self.lastSelectedProfileIDStorage, privacy: .public)")
        lastSelectedProfileIDStorage = id ?? ""
    }

    private func ensureSelection() {
        if selectedProfileID == nil || verifiedProfiles.allSatisfy({ $0.id != selectedProfileID }) {
            setSelectedProfileID(verifiedProfiles.first?.id)
        }
    }

    private func loadAPIKeys() {
        for profile in settings.aiProviderProfiles {
            apiKeys[profile.id] = (try? KeychainManager.shared.loadAIKey(forProvider: profile.id)) ?? ""
        }
    }

    private func beginDraft(provider: AIServiceProvider) {
        AppLog.ai.debug("[AISettings] beginDraft(provider:) called provider=\(provider.rawValue, privacy: .public) prevDraftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
        var profile = AIProviderProfile(provider: provider)
        // 草稿默认不启用，防止它在测试通过前进入任务模型选择或真实 AI 调用链。
        profile.isEnabled = false
        draftProfile = profile
        draftAPIKey = ""
        keyError = nil
    }

    private func beginDraft(from profile: AIProviderProfile) {
        AppLog.ai.debug("[AISettings] beginDraft(from:) called fromID=\(profile.id, privacy: .public) prevDraftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
        var copy = profile
        // 编辑已验证配置时也先变成草稿，同 ID 测试通过后覆盖原配置。这样用户改 Base URL
        // 或 API Key 时，不会让未验证的新值直接进入真实 AI 调用链。
        copy.isEnabled = false
        copy.lastTestStatus = .notTested
        draftProfile = copy
        draftAPIKey = apiKeys[profile.id, default: ""]
        keyError = nil
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        settings.aiProviderProfiles.removeAll { $0.id == id }
        try? KeychainManager.shared.deleteAIKey(forProvider: id)
        apiKeys.removeValue(forKey: id)
        setSelectedProfileID(verifiedProfiles.first?.id)
        repairTasksAfterProfileChange()
    }

    @MainActor
    private func testAndFetchModels(_ profile: AIProviderProfile) async {
        isTestingProfileID = profile.id
        keyError = nil
        defer { isTestingProfileID = nil }

        let testingKey = apiKey(for: profile)
        do {
            let models = try await OpenAIClient(configuration: AIClientConfiguration(
                providerID: profile.id,
                provider: profile.provider,
                apiKey: testingKey,
                baseURL: profile.baseURL,
                chatModel: profile.models.first(where: { $0.capability == .chat })?.name ?? profile.provider.defaultChatModel,
                embeddingModel: profile.models.first(where: { $0.capability == .embedding })?.name ?? profile.provider.defaultEmbeddingModel,
                timeoutInterval: 60
            )).listModels()

            var verified = profile
            mergeModels(models, into: &verified)
            verified.isEnabled = true
            verified.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
            verified.lastTestStatus = .success(modelCount: verified.models.count)

            try persistAPIKey(testingKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)

            if isActiveProfileDraft(profile.id) {
                var profiles = settings.aiProviderProfiles
                profiles.removeAll { $0.id == profile.id }
                profiles.append(verified)
                settings.aiProviderProfiles = profiles
                setSelectedProfileID(profile.id)
                draftProfile = nil
                draftAPIKey = ""
            } else {
                updateProfile(profile.id) { current in
                    current = verified
                }
            }
            apiKeys[profile.id] = testingKey
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
            if isActiveProfileDraft(profile.id) {
                draftProfile?.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                draftProfile?.lastTestStatus = .failed(error.localizedDescription)
            } else {
                updateProfile(profile.id) { current in
                    current.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                    current.lastTestStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func mergeModels(_ models: [AIModelDescriptor], into profile: inout AIProviderProfile) {
        let oldByName = Dictionary(uniqueKeysWithValues: profile.models.map { ($0.name, $0) })
        profile.models = models.map { incoming in
            if var old = oldByName[incoming.name] {
                old.ownedBy = incoming.ownedBy
                if old.capability == .unknown {
                    old.capability = incoming.capability
                }
                return old
            }
            return incoming
        }
    }

    private func persistAPIKey(_ rawKey: String, forProvider profileID: String, allowsEmpty: Bool) throws {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !allowsEmpty {
            throw AIClientError.missingAPIKey
        }
        if trimmed.isEmpty {
            try KeychainManager.shared.deleteAIKey(forProvider: profileID)
        } else {
            try KeychainManager.shared.storeAIKey(trimmed, forProvider: profileID)
        }
    }

    private func canTest(_ profile: AIProviderProfile) -> Bool {
        let hasBaseURL = !profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = !apiKey(for: profile).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasBaseURL && (profile.provider.allowsEmptyAPIKey || hasKey)
    }

    private func apiKey(for profile: AIProviderProfile) -> String {
        if isActiveProfileDraft(profile.id) {
            return draftAPIKey
        }
        return apiKeys[profile.id, default: ""]
    }

    private func isActiveProfileDraft(_ profileID: String) -> Bool {
        draftProfile?.id == profileID
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
            set: { newSelection in
                // macOS Picker 在 Form 刷新时可能把当前 selection 原样写回一次。
                // 新增草稿时第一行仍显示原已验证配置（如 DeepSeek），如果重复写回也清空
                // draftProfile，就会出现“输入任意字符后草稿 provider 跳回 DeepSeek”。
                // 只有用户真正切到另一个已验证配置时，才丢弃草稿。
                //
                // HOM-AIPROVIDERS-NIL-WRITEBACK-2026-06-06 (dong4j 反馈"+号后输入
                // 任意内容、Provider 立马跳到第一个已配置好的服务商"):
                // 13:18 的修复处理了"同值写回"(`newSelection == selectedProfileID`),
                // 但 macOS SwiftUI Picker 在某些刷新时机会把 selection 写回 **nil**——
                // 典型场景:用户点 + 后 draftProfile 一直是非 verified(`isEnabled=false`),
                // Form 内每次输入触发 body 重算时 NSPopUpButton 的内部 selectedIndex 与
                // 我们 binding 短暂不一致,SwiftUI 当作"找不到匹配 tag"主动写 nil 回来。
                // `nil != selectedProfileID(=A.id)` 让旧 guard 失守,setSelectedProfileID(nil)
                // 把持久化清空 + 把 draftProfile 也一并清掉,导致 activeProfile 回退到
                // verifiedProfiles.first(DeepSeek),Picker 2 跟着跳。
                //
                // 防御:Picker 1 的所有 tag 都是非 nil 的 verified profile ID,经过它的
                // `newSelection == nil` 100% 不是用户主动操作(用户没法选 nil tag),而是
                // SwiftUI 内部 sync 副作用。直接忽略,不让它清掉 draft。
                // 真正需要把 selectedProfileID 置 nil 的路径(deleteSelectedProfile 后
                // 没有 verified profile)走 setSelectedProfileID(nil) 直接调用,不经过此
                // binding,所以这个 guard 不会误伤合法的 nil 写入。
                AppLog.ai.debug("[AISettings] selectedProfileBinding.set newSelection=\(newSelection ?? "nil", privacy: .public) currentSelectedProfileID=\(self.selectedProfileID ?? "nil", privacy: .public) draftID=\(self.draftProfile?.id ?? "nil", privacy: .public)")
                guard let newSelection else {
                    AppLog.ai.debug("[AISettings] selectedProfileBinding.set: nil write blocked")
                    return
                }
                guard newSelection != selectedProfileID else {
                    AppLog.ai.debug("[AISettings] selectedProfileBinding.set: same-value write blocked")
                    return
                }
                AppLog.ai.debug("[AISettings] selectedProfileBinding.set: APPLYING — clearing draft")
                setSelectedProfileID(newSelection)
                draftProfile = nil
                draftAPIKey = ""
                keyError = nil
            }
        )
    }

    private var supportedProviderBinding: Binding<AIServiceProvider> {
        Binding(
            get: { activeProfile?.provider ?? .openAICompatible },
            set: { provider in
                if draftProfile == nil || draftProfile?.provider != provider {
                    beginDraft(provider: provider)
                }
            }
        )
    }

    // HOM-AIPROVIDERS-COORDINATOR-STALE-BINDING-2026-06-06
    // (dong4j 反馈"+号后输入框打字会跳回 verified profile" — log 抓到关键证据:
    //  beginDraft(from:) 被错误调用 fromID=verifiedA prevDraftID=newDraft).
    //
    // 根因:`ProviderSingleLineTextField` 是 NSViewRepresentable,Coordinator 在
    // makeCoordinator() 时持有当时的 binding。binding closure 之前 capture 了
    // **当时**的 `profileID`(verified A 的 id)。SwiftUI re-render 创建新 binding
    // (新的 profileID = draft.id),但 NSViewRepresentable 不会重建 Coordinator,
    // 它继续用最初的 binding。用户在 NSTextField 打字时,Coordinator 调旧 setter,
    // 闭包内的 profileID 仍是旧 verified A 的 id,走 isActiveProfileDraft FALSE 分支,
    // → beginDraft(from: A) → draft 被替换成 A 的 copy → UI 跳回 verified profile。
    //
    // 修复:binding closure **不依赖 captured profileID**,而是通过 `draftProfile` /
    // `selectedProfileID` 这两个 @State / @AppStorage 直接动态查最新状态。
    // SwiftUI @State 通过 wrapper 间接引用 SwiftUI 内部 storage,即使 self 是旧的
    // struct value,property wrapper 内部访问到的还是 latest storage,从而绕过
    // "Coordinator 持有 stale binding" 这个 NSViewRepresentable 的固有问题。
    //
    // 副作用:这两个 binding 的语义从"按 profileID 编辑"变成"按当前 active profile
    // 编辑"。view body 不再传 profileID。

    private func editableAPIKeyBinding() -> Binding<String> {
        Binding(
            get: {
                if draftProfile != nil {
                    return draftAPIKey
                }
                if let id = selectedProfileID {
                    return apiKeys[id, default: ""]
                }
                return ""
            },
            set: { newValue in
                if draftProfile != nil {
                    draftAPIKey = newValue
                } else if let id = selectedProfileID, let current = profile(id) {
                    AppLog.ai.debug("[AISettings] editableAPIKeyBinding.set: promoting verified \(id, privacy: .public) to draft")
                    beginDraft(from: current)
                    draftAPIKey = newValue
                }
            }
        )
    }

    private func editableProfileTextBinding(
        keyPath: WritableKeyPath<AIProviderProfile, String>
    ) -> Binding<String> {
        Binding(
            get: {
                if let draft = draftProfile {
                    return draft[keyPath: keyPath]
                }
                if let id = selectedProfileID, let p = profile(id) {
                    return p[keyPath: keyPath]
                }
                return ""
            },
            set: { newValue in
                if draftProfile != nil {
                    draftProfile?[keyPath: keyPath] = newValue
                    draftProfile?.lastTestStatus = .notTested
                } else if let id = selectedProfileID, let current = profile(id) {
                    AppLog.ai.debug("[AISettings] editableProfileTextBinding.set: promoting verified \(id, privacy: .public) to draft")
                    beginDraft(from: current)
                    draftProfile?[keyPath: keyPath] = newValue
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

    private var verifiedProfiles: [AIProviderProfile] {
        settings.aiProviderProfiles.filter(\.isVerifiedConfiguration)
    }

    private var activeProfile: AIProviderProfile? {
        draftProfile ?? selectedProfile
    }

    private var selectedProfile: AIProviderProfile? {
        guard let selectedProfileID else { return verifiedProfiles.first }
        return verifiedProfiles.first { $0.id == selectedProfileID }
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
        guard let profile = profile(providerID), profile.isVerifiedConfiguration else { return [] }
        return profile.models.filter {
            $0.isEnabled && ($0.capability == capability || $0.capability == .unknown)
        }
    }

    private func repairTasksAfterProfileChange() {
        for task in AIModelTask.allCases {
            let config = taskConfig(task)
            let models = enabledModels(providerID: config.providerID, capability: task.requiredCapability)
            let currentProfile = profile(config.providerID)
            if currentProfile?.isVerifiedConfiguration != true || (!config.useCustomModel && models.allSatisfy { $0.name != config.modelID }) {
                let fallbackProfile = verifiedProfiles.first
                updateTask(task) { updated in
                    updated.providerID = fallbackProfile?.id ?? ""
                    if let first = fallbackProfile.flatMap({ enabledModels(providerID: $0.id, capability: task.requiredCapability).first }) {
                        updated.modelID = first.name
                        updated.customModelName = first.name
                        updated.useCustomModel = false
                    } else {
                        updated.modelID = ""
                        updated.customModelName = ""
                        updated.useCustomModel = true
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

/// Provider 配置区专用单行输入框。
///
/// 为什么不用 SwiftUI 原生 `TextField`：
/// macOS `Form(.grouped)` 会把原生 TextField 的内容长度纳入布局协商，Cloudflare
/// 这类超长 Base URL 容易把行顶成换行或让三行输入框宽度不一致。这里窄范围桥接
/// AppKit，强制单行、禁 wrap、允许字段内部横向滚动；外层 SwiftUI 仍用
/// `.frame(maxWidth: .infinity)` 控制三行等宽和右侧铺满。
private struct ProviderSingleLineTextField: NSViewRepresentable {

    @Binding var text: String
    var isSecure: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let textField: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.controlSize = .regular
        textField.stringValue = text
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }
    }
}

/// HOM-AIPROVIDERS-DRAFT-DISCARD-2026-06-06 (dong4j 反馈):
/// SwiftUI 桥接 `NSWindow.willCloseNotification` 的窄范围监听器。
///
/// 用途:在 Settings 窗口真正关闭时通知 AI Tab 丢弃未完成草稿。
///
/// 关键约束 / 已踩过的坑:
/// - **必须把 observer 的 `object` 限定为 self.window**,而不是 nil。
///   nil 会让 observer 监听到 app 任意 NSWindow 关闭事件——主窗口关闭也会
///   误清掉 AI Tab 的 draft,把"打开 Starcat → 配 AI → 关主窗 → 重开 App"
///   的草稿连续性弄丢。
/// - **必须在 `viewDidMoveToWindow` 注册/反注册** 而不是 init / makeNSView:
///   NSViewRepresentable 创建 NSView 时尚未挂到窗口,self.window 是 nil;
///   `viewDidMoveToWindow` 在 view 加入 / 离开 window hierarchy 时都会触发,
///   是注册 window-scoped observer 的正确时机。
/// - **`[weak self]`** 防止 observer 强引用 self 造成 ListenerView 在窗口
///   关闭后还活着、漏掉 deinit。
/// - **不会被切 Tab 触发**:NSTabView 切 tab 是 NSTabView 内部行为,不动
///   NSWindow 生命周期,所以这个 observer 在 Settings 内部切 Tab 时静默不工作,
///   不会误清 draft。这是为什么这里坚持用 NSWindow 通知而不是 SwiftUI
///   `.onDisappear`(macOS 15 上 onDisappear 切 Tab 触发行为不一致)。
private struct SettingsWindowCloseListener: NSViewRepresentable {

    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ListenerView()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI 每次 body 重新执行时会创建新的 onClose 闭包(它捕获的是
        // 当前 body 调用时的 self snapshot,确保闭包内访问 @State 拿到的
        // 是最新存储引用),这里把新闭包刷新到 ListenerView。
        (nsView as? ListenerView)?.onClose = onClose
    }

    private final class ListenerView: NSView {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObserver()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onClose?()
            }
        }

        deinit {
            removeObserver()
        }

        private func removeObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }
    }
}
