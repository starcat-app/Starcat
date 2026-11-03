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
import UniformTypeIdentifiers

/// 主设置中的 AI 分类页。
///
/// 四个页面只重新组织既有配置，不复制 `AppSettings` 状态：模型是所有 AI 能力的
/// 上游依赖，自动化消费模型配置，搜索与索引承载本地检索数据准备，外部搜索独立配置。
enum AISettingsPage: Hashable {
    case models
    case automation
    case externalSearch
}

/// AI 设置分类页面。
struct AISettingsTab: View {

    let page: AISettingsPage

    @Environment(AppSettings.self) private var settings
    /// HOM-126：「立刻手动触发一次」按钮直接调度。@Environment 注入自 StarcatApp。
    @Environment(AutoTidyScheduler.self) private var autoTidyScheduler
    /// 模型与自动化配置继续复用应用级服务与业务权限。
    @Environment(AppDependencies.self) private var dependencies
    /// disclosureLabel 与草稿 Provider 收放等动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// 2026-06-16:`RelativeDateTimeFormatter` 默认走系统 locale,需显式注入跟随
    /// LocaleStore 切换。Settings scene 已挂 `appLocaleEnvironment()`。
    @Environment(\.locale) private var locale

    /// HOM-AIPROVIDERS-PERSIST-2026-06-06 (dong4j 反馈)：
    /// 之前用 `@State private var selectedProfileID: String?` 保存当前选中的服务商
    /// profile，关掉 Settings 窗口再打开就会被 SwiftUI 销毁重建，`selectedProfileID`
    /// 重置为 nil，`ensureSelection()` 强制把它落回 `verifiedProfiles.first`。
    /// 多 profile 场景（DeepSeek + OpenAI 都已验证、用户最后选的是 OpenAI）下，
    /// 用户每次进入 AI 设置都会被强行切回 DeepSeek（第一个），第二行 Provider
    /// picker 也跟着回到 DeepSeek，违反"进页面时显示当前选中的已配好服务商"诉求。
    ///
    /// 选择现在由 AppSettings 共用并持久化，沿用原 key 与空串 nil 哨兵，
    /// 让 toolbar 同步知道设置页当前查看的服务商。`ensureSelection()` 保留兜底逻辑：
    /// 持久化的 ID 在当前已验证列表里找不到（profile 被删 / 升级后改了 ID）时
    /// 降级到 `verifiedProfiles.first?.id`，避免"指向幽灵 profile"。
    /// 当前选中的服务商 profile ID。空串持久化值视为 nil。
    /// 真正的写入入口走 `setSelectedProfileID(_:)`，避免散落的赋值绕过空串哨兵。
    private var selectedProfileID: String? {
        settings.aiSettingsSelectedProfileID.isEmpty ? nil : settings.aiSettingsSelectedProfileID
    }

    @State private var apiKeys: [String: String] = [:]
    @State private var isTestingProfileID: String?
    /// 即时状态与历史验证分开，断线时保留菜单和任务绑定；旧请求由 revision 隔离。
    @State private var providerAvailability = SettingsConnectionTest<AIProviderConnectionVerifier.Result>()
    @State private var providerConnectionTest = AIProviderConnectionTest()
    @State private var testedAvailabilityRequest: AIClientConfiguration?
    @State private var hasLoadedAPIKeys = false
    @State private var availabilityRetryID = UUID()
    @State private var forceAvailabilityTest = false
    /// 新增和编辑复用同一草稿弹窗；父窗口关闭时同步取消，防止迟到请求写回。
    @State private var providerSetupSession: AIProviderSetupViewModel?
    /// 编辑入口捕获当前任务，弹窗始终写回该任务，不与另一个分段选择器争用状态。
    @State private var promptEditingTask: AIModelTask?
    /// 只管理页面展示，不持久化，也不因折叠或关闭总开关重置用户的自动化配置。
    @State private var isTagPolicyExpanded = false
    @State private var isAutoTidyRulesExpanded = false
    @State private var isListGroupingRulesExpanded = false
    /// 捕获打开时的服务商身份；弹窗按 ID 读取实时模型，不使用这份快照编辑数据。
    @State private var modelManagementProfile: AIProviderProfile?

    /// HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
    /// 删除服务商需要二次确认。删除会同步删 profile + Keychain key + 修复
    /// 任务绑定（`repairTasksAfterProfileChange`），属于不可逆破坏性操作，
    /// 走 `.confirmationDialog` 拦一道。`pendingDeleteProfileID` 持有待删
    /// 目标的 ID 而非整个 profile，避免 dialog 弹起期间 `verifiedProfiles`
    /// 数组变化导致引用悬空（异步刷新 / @AppStorage 写回都可能触发刷新）。
    @State private var pendingDeleteProfileID: String?

    /// 这里只切换生成任务；共享向量模型独立展示，仍写入原 aiEmbeddingTask。
    @State private var taskModelTask: AIModelTask = .summary

    /// 跨服务商同名模型必须保留复合身份，自定义项只呈现现有配置，不触发额外写入。
    private typealias TaskModelChoice = AITaskModelPicker.Selection

    // HOM-68 follow-up v9：原"模型参数"区已迁到"已发现模型"每行的齿轮 popover
    // （模型粒度，不再按任务），不再需要 isParametersExpanded SceneStorage。
    private static let taskModelsSettingsAnchor = "settings.ai.taskModels"
    private static let embeddingSettingsAnchor = "settings.ai.sharedEmbedding"
    private static let externalSearchSettingsAnchor = "settings.ai.externalSearch"

    /// 免费用户点击 AI 设置页升级入口时展示统一 Pro 付费墙。
    @State private var paywallContext: ProPaywallContext?
    /// CC Switch 导入预览。确认前不写 Keychain。
    @State private var ccSwitchImportSession: CCSwitchImportSession?
    @State private var ccSwitchImportError: String?

    init(page: AISettingsPage = .models) {
        self.page = page
    }

    /// 模型与自动化继续遵守既有 Pro / Apple Silicon Local AI 门控；
    /// 免费的联网搜索和仓库上下文不使用此配置权限。
    private var hasAIConfigurationAccess: Bool {
        dependencies.entitlementGate.isProUser || LocalAIHardwareSupport.isLocalAIAvailable
    }

    @ViewBuilder
    var body: some View {
        // AI 服务是 Direct / StoreKit 共享的 Pro 能力，必须读取聚合后的业务门控；
        // 直接读取 SubscriptionManager 会把 Direct License 用户误判为未开通。
        // 本地 AI 免费（dong4j 2026-09-12）：Apple Silicon 上免费用户也必须能进入
        // 本页配置并下载本地模型；远程 provider 的消费仍由 EntitlementGate 在调用点拦截，
        // 设置页只是配置面。知识库索引配置对免费用户同样开放。
        if page == .externalSearch || hasAIConfigurationAccess {
            aiConfigurationForm
        } else {
            lockedAISettings
        }
    }

    private var aiConfigurationForm: some View {
        ScrollViewReader { proxy in
        // HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
        // 删除独立的"模型参数"区。原因：参数与"任务"绑定有歧义——同一模型被
        // 摘要 / 标签 / 翻译复用时，按任务调参数会出现"在'模型参数 → 摘要'调
        // temperature 只对'用 X 模型的摘要任务'生效，其它任务用 X 模型还是默认值"
        // 的反直觉行为。改成每行模型一个齿轮按钮 + popover，参数与"模型"绑定。
        Form {
            switch page {
            case .models:
                modelsIntroductionSection
                providerSection
                // 本地模型只在选中 Starcat Local AI 时出现，避免远程供应商页面
                // 同时展示无关下载项；模型与任务绑定按依赖顺序从上到下排列。
                if LocalAIHardwareSupport.isLocalAIAvailable, activeProfile?.provider == .localAI {
                    LocalAIModelsSection(settings: dependencies.settings)
                }
                taskModelsSection
                    .id(Self.taskModelsSettingsAnchor)
                sharedEmbeddingSection
                    .id(Self.embeddingSettingsAnchor)
                modelManagementAdvancedSection
            case .automation:
                // 两项都消费上游模型配置，但彼此不是父子能力，保留独立顶级 Section。
                automationIntroductionSection
                autoTidySection
                githubListGroupingSection
                automationModelsSection
            case .externalSearch:
                // 联网搜索原本对所有用户可配置，因此独立页面不能被 AI Pro 门控隐藏。
                ExternalSearchSettingsSection()
                    .id(Self.externalSearchSettingsAnchor)
            }
        }
        .alert(
            "settings.ai.provider.importCCSwitch",
            isPresented: Binding(
                get: { ccSwitchImportError != nil },
                set: { if !$0 { ccSwitchImportError = nil } }
            )
        ) {
            Button("general.cancel", role: .cancel) {}
        } message: {
            Text(ccSwitchImportError ?? "")
        }
        .sheet(item: $ccSwitchImportSession) { session in
            CCSwitchImportPreviewSheet(
                preview: session.preview,
                onImport: { candidates, progress in
                    await importCCSwitchCandidates(candidates, progress: progress)
                },
                onSelectProfile: { profileID in
                    setSelectedProfileID(profileID)
                }
            )
        }
        .sheet(item: providerSetupPresentation) { session in
            AIProviderSetupSheet(viewModel: session, onAdd: saveVerifiedProvider)
                .id(session.id)
                .appLocaleEnvironment()
        }
        .sheet(item: $promptEditingTask) { task in
            AITaskPromptSheet(
                task: task,
                systemPrompt: promptSystemBinding(task),
                userPromptTemplate: promptUserBinding(task),
                onRestoreDefault: { restoreDefaultPrompt(task) }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $modelManagementProfile) { profile in
            AIModelManagementSheet(
                providerID: profile.id,
                enabledBinding: { model in modelEnabledBinding(profile.id, model.id) },
                capabilityBinding: { model in modelCapabilityBinding(profile.id, model.id) },
                parametersBinding: { model in modelParametersBinding(profile.id, model.id) }
            )
            .appLocaleEnvironment()
        }
        .formStyle(.grouped)
        .task(id: page) {
            guard page == .models else { return }
            ensureSelection()
            loadAPIKeys()
            hasLoadedAPIKeys = true
        }
        .task(id: availabilityTaskID) {
            // 等待密钥加载完成再发请求，避免把未加载的凭据误报成认证失败。
            guard !Task.isCancelled else { return }
            providerAvailability.invalidate()
            let request = availabilityRequest
            testedAvailabilityRequest = request
            let force = forceAvailabilityTest
            forceAvailabilityTest = false
            guard let request, !TestEnvironment.isRunning else { return }
            await providerAvailability.run {
                // SwiftUI 取消切换前的等待任务，但网络请求由会话持有，切换回来可复用。
                try await providerConnectionTest.check(request, force: force)
            }
        }
        .onDisappear {
            providerAvailability.invalidate()
            providerConnectionTest.cancelAll()
            testedAvailabilityRequest = nil
            hasLoadedAPIKeys = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIEmbeddingSection)) { _ in
            guard page == .models else { return }
            // 向量模型已独立分组；深链直接定位，不改变生成任务的当前选择。
            DispatchQueue.main.async {
                proxy.scrollTo(Self.embeddingSettingsAnchor, anchor: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIChatModelSection)) { _ in
            guard page == .models else { return }
            // 从工作台缺少模型提示进入时，直接选中“对话”并定位常驻分组。
            taskModelTask = .chat
            DispatchQueue.main.async {
                proxy.scrollTo(Self.taskModelsSettingsAnchor, anchor: .top)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
            guard page == .externalSearch,
                  let target = note.object as? String,
                  target == "integrations.externalSearch" || target == "ai.externalSearch" else { return }
            DispatchQueue.main.async {
                proxy.scrollTo(Self.externalSearchSettingsAnchor, anchor: .top)
            }
        }
        // 只监听所属设置窗口；关闭时同步失效会话，防止网络回调在退场动画期间保存。
        .background(SettingsWindowCloseListener {
            providerSetupSession?.cancel()
            providerSetupSession = nil
            providerAvailability.invalidate()
            providerConnectionTest.cancelAll()
            testedAvailabilityRequest = nil
            hasLoadedAPIKeys = false
        })
        // HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
        // 删除服务商二次确认。用 `presenting:` 把 profile 注入到 alert 闭包，
        // 让按钮标题能显示具体服务商名（"删除「DeepSeek」"），减少误删风险。
        // 用 `pendingDeleteProfileID` 而非整个 profile 作为状态源，避免数组刷新
        // 期间引用悬空（见 `pendingDeleteProfileID` 注释）。
        .alert(
            "settings.ai.provider.deleteConfirm.title",
            isPresented: deleteConfirmationBinding,
            presenting: pendingDeleteProfile
        ) { profile in
            Button(role: .destructive) {
                deleteProfile(id: profile.id)
            } label: {
                Text(String(format: String.l10n("settings.ai.provider.deleteConfirm.confirmFormat"), profile.displayName))
            }
            Button("settings.common.cancel", role: .cancel) {
                pendingDeleteProfileID = nil
            }
        } message: { profile in
            Text(String(format: String.l10n("settings.ai.provider.deleteConfirm.messageFormat"), profile.displayName))
        }
        }
    }

    private var lockedAISettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        ProCrownIcon(size: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("settings.ai.locked.title")
                                .font(.title3.weight(.semibold))
                            Text("settings.ai.locked.subtitle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("settings.ai.locked.benefit.byok", systemImage: "key.fill")
                        Label("settings.ai.locked.benefit.workflow", systemImage: "sparkles")
                        Label("settings.ai.locked.benefit.billing", systemImage: "creditcard")
                    }
                    .font(.callout)

                    Button {
                        paywallContext = ProPaywallContext(
                            feature: .aiSummary,
                            message: String.l10n("settings.ai.locked.paywallMessage")
                        )
                    } label: {
                        Text("settings.ai.locked.upgrade")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("settings.ai.locked.footer")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
    }

    /// 二次确认 dialog 的 isPresented 绑定。
    /// set 时支持外部把它置 false（点 macOS 系统返回 / 点空白处关 dialog），
    /// 同步清掉 `pendingDeleteProfileID` 避免下次再弹时残留旧目标。
    private var deleteConfirmationBinding: Binding<Bool> {
        return Binding(
            get: { pendingDeleteProfileID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteProfileID = nil
                }
            }
        )
    }

    /// 当前待删除目标的 profile。pendingDeleteProfileID 持有 ID 而非整个 profile，
    /// 这里实时查表，避免数组刷新引用悬空。如果 ID 找不到对应 profile（删除瞬间数据
    /// 已变），返回 nil 让 dialog 自然 dismiss（`confirmationDialog(presenting:)` 在
    /// presenting 为 nil 时不展示 content）。
    private var pendingDeleteProfile: AIProviderProfile? {
        guard let id = pendingDeleteProfileID else { return nil }
        return profile(id)
    }

    /// 真删除入口，由 confirmationDialog 内部按钮调用。
    /// 既有的 `deleteSelectedProfile()` 隐式依赖 `selectedProfileID`，但二次确认
    /// 期间用户可能切换了 selection，所以这里收紧到「按显式 ID 删除」，与
    /// pendingDeleteProfileID 的语义一致，避免误删。
    private func deleteProfile(id: String) {
        AppLog.ai.debug("[AISettings] deleteProfile(id:) confirmed id=\(id, privacy: .public)")
        settings.aiProviderProfiles.removeAll { $0.id == id }
        try? KeychainManager.shared.deleteAIKey(forProvider: id)
        apiKeys.removeValue(forKey: id)
        // 被删的恰好是当前 selected 时，回退到剩余 verified 中的第一个；
        // 否则保持当前 selection 不动（删的是非当前项时，用户视线不应被打断）。
        if selectedProfileID == id {
            setSelectedProfileID(pickerProfiles.first?.id)
        }
        repairTasksAfterProfileChange()
        pendingDeleteProfileID = nil
    }

    // MARK: - Provider

    /// 系统主动结束 sheet 时也立即失效会话，不能只依赖退场动画后的 onDisappear。
    private var providerSetupPresentation: Binding<AIProviderSetupViewModel?> {
        Binding(
            get: { providerSetupSession },
            set: { session in
                if session == nil { providerSetupSession?.cancel() }
                providerSetupSession = session
            }
        )
    }

    /// 与通用和隐私页保持同一说明卡片结构，使用 Form 自带表面，不再套第二层背景。
    private var modelsIntroductionSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "cpu")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.models.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.models.title"))
                    Text("settings.models.introduction")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.models.introduction"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 验证器没有写入副作用；确认成功且会话仍有效后，才同步保存凭据与配置。
    /// Keychain 先写，失败则抛回弹框，避免未保存密钥的服务商进入任务选择。
    @MainActor
    private func saveVerifiedProvider(_ profile: AIProviderProfile, apiKey: String) throws {
        guard let session = providerSetupSession,
              session.profile.id == profile.id else { throw CancellationError() }
        if session.isEditing {
            // 原位替换，保留服务商 ID 和列表顺序；目标已删除时不能被迟到结果重新创建。
            var profiles = settings.aiProviderProfiles
            guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw CancellationError()
            }
            try persistAPIKey(apiKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)
            profiles[index] = profile
            settings.aiProviderProfiles = profiles
        } else {
            try persistAPIKey(apiKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)
            settings.aiProviderProfiles.append(profile)
        }
        apiKeys[profile.id] = apiKey
        setSelectedProfileID(profile.id)
        // 同输入重测成功时配置身份不变，也要让状态行读取刚完成的检测结果。
        availabilityRetryID = UUID()
        repairTasksAfterProfileChange()
    }

    /// 捕获当前配置创建编辑草稿，仍走现有模型发现与引用保护；打开窗口不写入配置。
    private func editSelectedProvider() {
        guard let profile = selectedProfile, profile.provider != .localAI else { return }
        providerSetupSession = AIProviderSetupViewModel(
            editingProfile: profile,
            existingAPIKey: apiKeys[profile.id, default: ""],
            verify: { draft, apiKey in
                try await providerConnectionTest.verify(
                    profile: draft,
                    apiKey: apiKey,
                    referencedModelNames: referencedModelNames(for: draft.id)
                )
            }
        )
    }

    private var providerSection: some View {
        Section {
            // 配置行只保留选择、修改与新增；低频的导入和删除放在下方模型状态行。
            HStack(alignment: .center, spacing: 8) {
                Text("settings.ai.provider.pickerLabel")
                    .font(.body)
                    .frame(width: 96, alignment: .leading)
                    .lineLimit(1)

                if pickerProfiles.isEmpty {
                    Text("settings.ai.provider.empty")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 8)
                    Picker("settings.ai.provider.pickerLabel", selection: selectedProfileBinding) {
                        ForEach(pickerProfiles) { profile in
                            Label {
                                Text(profile.displayName)
                            } icon: {
                                AIProviderIconView(provider: profile.provider, size: 14)
                            }
                            .tag(Optional(profile.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                if let profile = selectedProfile, profile.provider != .localAI {
                    SettingsActionIconButton(
                        title: "settings.ai.provider.edit.help",
                        systemImage: "pencil"
                    ) {
                        editSelectedProvider()
                    }
                    .disabled(isTestingProfileID != nil || providerSetupSession != nil)
                }

                AddIconButton(help: Text("settings.ai.provider.addHelp")) {
                    providerSetupSession = AIProviderSetupViewModel(verify: { draft, apiKey in
                        try await providerConnectionTest.verify(profile: draft, apiKey: apiKey)
                    })
                }
                .disabled(isTestingProfileID != nil || providerSetupSession != nil)
            }

            HStack(alignment: .center, spacing: 8) {
                if selectedProfile != nil {
                    providerAvailabilityStatus
                }

                Spacer(minLength: 8)

                SyncIconButton(
                    isRefreshing: isAvailabilityTesting,
                    disabled: selectedProfile == nil || isAvailabilityTesting || isTestingProfileID != nil,
                    // 环形箭头视觉偏大，较标准图标缩小 1pt；命中区仍与相邻按钮一致。
                    font: .system(size: SettingsIconMetrics.standardGlyphSize - 1, weight: .medium),
                    frameSize: SettingsIconMetrics.actionFrameSize,
                    tooltip: String.l10n("settings.ai.provider.testButton")
                ) {
                    providerAvailability.invalidate()
                    testedAvailabilityRequest = nil
                    forceAvailabilityTest = true
                    availabilityRetryID = UUID()
                }

                ImportIconButton(
                    help: Text("settings.ai.provider.importCCSwitch.help"),
                    image: Image("CCSwitch")
                ) {
                    beginCCSwitchImport()
                }
                .disabled(isTestingProfileID != nil || providerSetupSession != nil)

                DestructiveIconButton(
                    help: Text("settings.ai.provider.deleteHelp"),
                    font: SettingsIconMetrics.standardGlyph,
                    frameSize: SettingsIconMetrics.actionFrameSize
                ) {
                    pendingDeleteProfileID = selectedProfileID
                }
                .disabled(selectedProfile == nil || selectedProfile?.provider == .localAI)
            }

            if selectedProfile?.provider == .localAI {
                Text("settings.localai.provider.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            SettingsSectionHeader(
                "settings.models.provider.section",
                systemImage: "server.rack"
            )
        }
    }

    /// 配置一变就不显示旧结果，避免 SwiftUI 新任务尚未启动时短暂沿用上个服务商的绿标。
    private var isAvailabilityTesting: Bool {
        availabilityRequest != nil
            && (testedAvailabilityRequest != availabilityRequest || providerAvailability.isTesting)
    }

    @ViewBuilder
    private var providerAvailabilityStatus: some View {
        let isCurrent = testedAvailabilityRequest == availabilityRequest
        let error = isCurrent ? providerAvailability.errorMessage : nil
        let result = isCurrent ? providerAvailability.result : nil
        let summary = if isAvailabilityTesting {
            String.l10n("settings.ai.provider.setup.testing")
        } else if let error {
            error
        } else if let result {
            result.models.isEmpty
                ? String.l10n("settings.ai.provider.availability.noModels")
                : String(
                    format: String.l10n("settings.ai.provider.availability.successFormat"),
                    result.models.count.formatted(.number.locale(locale))
                )
        } else {
            String.l10n("ai.connectionTest.notTested")
        }
        let appearance: (symbol: String, color: Color) = if isAvailabilityTesting {
            ("network", .accentColor)
        } else if error != nil {
            ("exclamationmark.circle", .red)
        } else if let result {
            result.models.isEmpty
                ? ("exclamationmark.triangle", .orange)
                : ("checkmark.circle", .green)
        } else {
            ("questionmark.circle", .secondary)
        }
        Label(summary, systemImage: appearance.symbol)
            .font(.caption)
            .foregroundStyle(appearance.color)
            // 不为单行提示预留第二行，避免文字上移；长错误按需换行并与操作区整体居中。
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(summary)
    }

    /// 页面生命周期与请求输入共同触发测试；手动重试只改变 nonce，不重写配置。
    private struct AvailabilityTaskID: Equatable {
        let request: AIClientConfiguration?
        let retryID: UUID
    }

    private var availabilityRequest: AIClientConfiguration? {
        guard page == .models, hasLoadedAPIKeys, let profile = selectedProfile else { return nil }
        return AIProviderConnectionVerifier.configuration(
            profile: profile, apiKey: apiKeys[profile.id] ?? ""
        )
    }

    private var availabilityTaskID: AvailabilityTaskID {
        AvailabilityTaskID(request: availabilityRequest, retryID: availabilityRetryID)
    }

    /// 高级配置常驻显示；模型列表仍在当前服务商的管理弹窗中编辑。
    private var modelManagementAdvancedSection: some View {
        Section {
            centeredModelSettingRow {
                Button("settings.ai.models.management.open") {
                    // 只确定本次管理对象；编辑仍通过原模型绑定即时写回。
                    modelManagementProfile = selectedProfile
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(selectedProfile == nil)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.management.available")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.management.available"))
                    Text("settings.ai.models.management.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.management.help"))
                }
            }
        } header: {
            SettingsSectionHeader("settings.ai.models.advanced.title", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: - Tasks

    /// 三个生成任务共享同一套原生配置行，各自的模型与提示词仍独立保存。
    private var taskModelsSection: some View {
        Section {
            centeredModelSettingRow {
                Picker("settings.ai.task.pickerLabel", selection: $taskModelTask) {
                    ForEach(AIModelTask.aiSettingsPageTasks) { task in
                        Text(LocalizedStringKey(task.displayNameKey)).tag(task)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.task.pickerLabel")
                        .lineLimit(1)
                        .help(Text("settings.ai.task.pickerLabel"))
                    Text("settings.ai.models.task.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.task.help"))
                }
            }

            centeredModelSettingRow {
                taskModelPicker(taskModelTask, label: "settings.ai.models.model.title")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.model.title")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.model.title"))
                    Text("settings.ai.models.model.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.model.help"))
                }
            }

            centeredModelSettingRow {
                Button("settings.ai.models.prompt.edit") {
                    promptEditingTask = taskModelTask
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.prompt.title")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.prompt.title"))
                    Text(LocalizedStringKey(isDefaultPrompt(taskModelTask)
                        ? "settings.ai.models.prompt.default" : "settings.ai.models.prompt.custom"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            taskCustomModelConfiguration(taskModelTask)
        } header: {
            SettingsSectionHeader("settings.ai.models.defaults.title", systemImage: "slider.horizontal.3")
        }
    }

    /// 一个原生菜单汇总已验证服务商的适用模型，保留自定义及暂不可用配置的显示身份。
    private func taskModelPicker(_ task: AIModelTask, label: LocalizedStringKey) -> some View {
        let config = taskConfig(task)
        let profiles = eligibleVerifiedProfiles(for: task)
        let providerName = profile(config.providerID)?.displayName ?? config.providerID

        return AITaskModelPicker(
            title: label,
            profiles: profiles,
            selection: taskModelChoiceBinding(task),
            providerDisplayName: providerName
        ) { provider in
            enabledModels(providerID: provider.id, capability: task.requiredCapability)
        }
    }

    /// 开关直接控制名称行显隐；沿用原绑定，关闭时保留输入及当前服务商。
    @ViewBuilder
    private func taskCustomModelConfiguration(_ task: AIModelTask) -> some View {
        Toggle("settings.ai.task.customModelLabel", isOn: taskCustomEnabledBinding(task))
            .toggleStyle(.switch)
            .lineLimit(1)
            .help(Text("settings.ai.task.customModelLabel"))
        if taskConfig(task).useCustomModel {
            LabeledContent {
                TextField("settings.ai.models.custom.name", text: taskCustomModelBinding(task))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .disableAutocorrection(true)
            } label: {
                Text("settings.ai.models.custom.name")
                    .lineLimit(1)
                    .help(Text("settings.ai.models.custom.name"))
            }
        }
    }

    /// LabeledContent 默认按首行基线排版；双行说明改用原生 HStack 让整个文本块与控件居中。
    private func centeredModelSettingRow<Content: View, RowLabel: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> RowLabel
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 语义搜索与知识库检索只保留一个向量模型入口，索引管理仍跳转到各自现有页面。
    private var sharedEmbeddingSection: some View {
        Section {
            centeredModelSettingRow {
                taskModelPicker(.embedding, label: "settings.ai.models.embedding.model")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.embedding.model")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.embedding.model"))
                    Text("settings.ai.models.embedding.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.embedding.help"))
                }
            }
            Text("settings.ai.models.embedding.storageHint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("settings.ai.models.embedding.index.title") {
                HStack(spacing: 12) {
                    Button("settings.ai.models.embedding.index.repo") {
                        NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.index")
                    }
                    .help(Text("settings.ai.models.embedding.index.repo"))
                    Button("settings.ai.models.embedding.index.knowledge") {
                        NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.knowledgeIndex")
                    }
                    .help(Text("settings.ai.models.embedding.index.knowledge"))
                }
                .buttonStyle(.link)
                .controlSize(.regular)
                .lineLimit(1)
            }

            centeredModelSettingRow {
                Button("settings.ai.models.prompt.edit") {
                    promptEditingTask = .embedding
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.embedding.template.title")
                        .lineLimit(1)
                        .help(Text("settings.ai.models.embedding.template.title"))
                    Text("settings.ai.models.embedding.template.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.ai.models.embedding.template.help"))
                }
            }

            taskCustomModelConfiguration(.embedding)
        } header: {
            SettingsSectionHeader("settings.ai.models.embedding.title", systemImage: "point.3.connected.trianglepath.dotted")
        } footer: {
            Text("settings.ai.models.embedding.footer")
        }
    }

    /// 状态文案只对比当前任务的已存提示词与默认值，不写入或恢复任何配置。
    private func isDefaultPrompt(_ task: AIModelTask) -> Bool {
        let defaults: AIPromptConfiguration
        switch task {
        case .summary: defaults = AIDefaultPrompts.summary
        case .tags: defaults = AIDefaultPrompts.tags
        case .chat: defaults = AIDefaultPrompts.chat
        case .embedding: defaults = AIDefaultPrompts.embedding
        case .translation: defaults = AIDefaultPrompts.translation
        }
        return taskConfig(task).prompt == defaults
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
    private func disclosureLabel(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    // 与 SettingsSectionHeader prominent 的分组图标同口径（13pt / 20×20），
                    // 让 DisclosureGroup 标题和 Section 分组标题在 Form 里同一视觉层级。
                    .font(SettingsIconMetrics.smallGlyph)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                Text(titleKey)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // HOM-68 follow-up v10 (dong4j 反馈 2026-06-05 23:55)：项目强制规则
        // (docs/3-设计/详细设计/07-UI交互设计.md §1.2 + CLAUDE.md §UI Focus Ring)——
        // 所有 .buttonStyle(.plain) Button 必须紧跟 .focusEffectDisabled()，否则
        // macOS 15+ 会在聚焦时套一个蓝色 focus ring，与项目暗色面板视觉冲突。
        .focusEffectDisabled()
    }

    // MARK: - Auto Tidy (HOM-126)

    /// 沿用模型与翻译页的说明卡片结构，卡片表面由原生 grouped Form 提供。
    private var automationIntroductionSection: some View {
        Section {
            HStack(spacing: 16) {
                BusinessIcon(.automation, pointSize: 24)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.automation.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.automation.title"))
                    Text("settings.automation.introduction.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.automation.introduction.description"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 常用操作常驻；标签细节与运行规则并列折叠。总开关的禁用范围保持原样，
    /// 包括运行状态和手动执行，避免仅调整布局时改变调度器的使用条件。
    private var autoTidySection: some View {
        Section {
            autoTidyContent
        } header: {
            SettingsSectionHeader(
                "settings.automation.local.section",
                businessIcon: .tags
            )
        }
    }

    /// 仓库分组的独立全局配置。
    ///
    /// 标签是 Starcat 本地数据，而仓库分组会写入 GitHub Lists。两者的授权边界和
    /// 置信度不能放在同一个配置组里，否则调整标签策略时可能意外改变远端写入行为。
    /// 常用阈值常驻，自己的运行规则默认收起，不能与本地整理共享折叠或配置状态。
    private var githubListGroupingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                // 与本地整理总开关同款：标题与备注分行，避免 Toggle thumb 被挤出裁切。
                // 备注只说后台整理未分组仓库；启动 / 同步触发已拆到下方独立开关，不能再写死。
                Toggle("settings.automation.grouping.enabled", isOn: githubListGroupingBinding(\.enabled))
                    .toggleStyle(.switch)
                    .padding(.vertical, 8)

                Text("settings.githubListGrouping.enabled.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                Group {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsSliderRow(
                            title: "settings.githubListGrouping.threshold.label",
                            value: githubListGroupingBinding(\.confidenceThreshold),
                            range: 0.5...1.0, step: 0.05,
                            readout: githubListGroupingThresholdPercentString
                        )
                        Text(String(
                            format: String.l10n("settings.githubListGrouping.threshold.hintFormat"),
                            githubListGroupingThresholdPercentString
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)

                    Divider()
                    automationDisclosure(
                        "settings.automation.rules.title",
                        summary: listGroupingRulesSummary,
                        isExpanded: $isListGroupingRulesExpanded
                    ) {
                        githubListGroupingTriggerGroup
                        githubListGroupingRangeGroup
                    }
                }
                .disabled(!settings.githubStarListAutoGroupingSettings.enabled)
                .opacity(settings.githubStarListAutoGroupingSettings.enabled ? 1.0 : 0.5)
            }
            .padding(.top, 4)
        } header: {
            SettingsSectionHeader(
                "settings.automation.grouping.section",
                businessIcon: .groups
            )
        } footer: {
            Text("settings.githubListGrouping.footer")
        }
    }

    /// 仓库分组拥有自己的触发策略，不能借用标签整理开关；否则用户关闭“同步后加标签”
    /// 时会意外停止 GitHub Lists 整理，或反过来被不相关的触发器启动。
    @ViewBuilder
    private var githubListGroupingTriggerGroup: some View {
        Divider()

        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onLaunch",
                description: "settings.githubListGrouping.trigger.onLaunch.description",
                isOn: githubListGroupingBinding(\.triggerOnLaunch)
            )
        }
        Divider()
        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onSync",
                description: "settings.githubListGrouping.trigger.onSync.description",
                isOn: githubListGroupingBinding(\.triggerOnSync)
            )
        }
        Divider()
        autoTidyRow {
            Toggle(
                "settings.autoTidy.trigger.scheduled",
                isOn: githubListGroupingBinding(\.triggerScheduled)
            )
        }
        Divider()
        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: githubListGroupingScheduledIntervalHoursBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("1 - 24")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.trigger.scheduledInterval",
                    description: "settings.autoTidy.trigger.scheduledInterval.description"
                )
            }
            .disabled(!settings.githubStarListAutoGroupingSettings.triggerScheduled)
            .opacity(settings.githubStarListAutoGroupingSettings.triggerScheduled ? 1.0 : 0.5)
        }
    }

    /// 后台分组只从“未分组”仓库里按此范围取候选；v34 持久化的 OAuth 限制仓库会在
    /// 截取批量前排除，不能占用用户配置的单轮数量。
    @ViewBuilder
    private var githubListGroupingRangeGroup: some View {
        Divider()

        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: githubListGroupingMaxPerRunBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("5 - 500")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.maxPerRun",
                    description: "settings.githubListGrouping.range.maxPerRun.description"
                )
            }
        }
        Divider()
        autoTidyRow {
            Picker(selection: githubListGroupingBinding(\.sortOrder)) {
                ForEach(AutoTidySortOrder.allCases) { order in
                    Text(order.displayNameKey).tag(order)
                }
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.sortOrder",
                    description: "settings.githubListGrouping.range.sortOrder.description"
                )
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var autoTidyContent: some View {
        // 配置面板内不会自动出现 Form 行分隔线，
        // 改用 VStack(spacing: 0) + Divider + 统一行 padding，对齐通用设置页节奏。
        VStack(spacing: 0) {
            // 总开关：标题行与说明分两行，避免 LabeledContent 把 Toggle thumb 挤出裁切。
            Toggle("settings.automation.local.enabled", isOn: autoTidyBinding(\.enabled))
                .toggleStyle(.switch)
                .padding(.vertical, 8)

            Text("settings.autoTidy.enabled.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            Group {
                Divider()
                autoTidyRow {
                    autoTidyToggle(
                        title: "settings.autoTidy.actions.generateTags",
                        description: "settings.autoTidy.actions.generateTags.description",
                        isOn: autoTidyBinding(\.generateTags)
                    )
                }
                Divider()
                autoTidyRow {
                    autoTidyToggle(
                        title: "settings.autoTidy.actions.generateSummary",
                        description: "settings.autoTidy.actions.generateSummary.description",
                        isOn: autoTidyBinding(\.generateSummary)
                    )
                }
                Divider()
                automationDisclosure(
                    "settings.automation.tagPolicy.title",
                    summary: tagPolicySummary,
                    isExpanded: $isTagPolicyExpanded
                ) {
                    tagPolicyGroup
                }
                .disabled(!settings.autoTidySettings.generateTags)
                .opacity(settings.autoTidySettings.generateTags ? 1.0 : 0.5)

                Divider()
                automationDisclosure(
                    "settings.automation.rules.title",
                    summary: autoTidyRulesSummary,
                    isExpanded: $isAutoTidyRulesExpanded
                ) {
                    triggerGroup
                    rangeGroup
                }
                statusGroup
            }
            .disabled(!settings.autoTidySettings.enabled)
            .opacity(settings.autoTidySettings.enabled ? 1.0 : 0.5)
        }
        .padding(.top, 4)
    }

    /// 整行切换展开，右侧箭头只表达状态；摘要可截断但完整内容保留在 tooltip 和辅助功能中。
    private func automationDisclosure<Content: View>(
        _ title: LocalizedStringKey,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(verbatim: summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(summary))
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: [
                String.l10n(isExpanded.wrappedValue
                    ? "settings.general.disclosure.expanded"
                    : "settings.general.disclosure.collapsed"),
                summary
            ].joined(separator: " · ")))

            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    /// 跳转已有任务模型页，不在自动化页面复制模型配置或增加第二份状态。
    private var automationModelsSection: some View {
        Section {
            HStack {
                Spacer()
                Button("settings.automation.manageModels") {
                    NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.models")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    /// 配置行统一竖向 padding，避免 Toggle / LabeledContent / Picker 行高不一致。
    private func autoTidyRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 8)
    }

    /// 标题 + caption 备注：设置页行 Label 标准结构（见 UI-设置页规范）。
    private func autoTidyLabel(title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 带备注的 Toggle，避免每个开关重复拼 VStack。
    private func autoTidyToggle(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            autoTidyLabel(title: title, description: description)
        }
    }

    /// 触发时机：启动后一次 / 同步后增量 / 定时（可配间隔）。
    @ViewBuilder
    private var triggerGroup: some View {
        Divider()

        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onLaunch",
                description: "settings.autoTidy.trigger.onLaunch.description",
                isOn: autoTidyBinding(\.triggerOnLaunch)
            )
        }
        Divider()
        autoTidyRow {
            autoTidyToggle(
                title: "settings.autoTidy.trigger.onSync",
                description: "settings.autoTidy.trigger.onSync.description",
                isOn: autoTidyBinding(\.triggerOnSync)
            )
        }
        Divider()
        autoTidyRow {
            Toggle("settings.autoTidy.trigger.scheduled", isOn: autoTidyBinding(\.triggerScheduled))
        }
        Divider()

        // 间隔仅在「定时执行」打开时有意义；关掉时淡化 + disable，保留上次填写值。
        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: scheduledIntervalHoursBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("1 - 24")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.trigger.scheduledInterval",
                    description: "settings.autoTidy.trigger.scheduledInterval.description"
                )
            }
            .disabled(!settings.autoTidySettings.triggerScheduled)
            .opacity(settings.autoTidySettings.triggerScheduled ? 1.0 : 0.5)
        }
    }

    /// 处理范围：批处理数量 + 处理优先级。
    @ViewBuilder
    private var rangeGroup: some View {
        Divider()

        // HOM-126 follow-up (dong4j 反馈 2026-06-07)：Stepper → TextField + 数字校验。
        // SwiftUI `TextField(value:format: .number)` 内置只接受数字输入（非数字字符被吃掉），
        // setter 在 `maxPerRunBinding` 内已 clamp 到 5...500，超范围 / 失焦后 binding 把值约束回区间。
        // 用 `IntegerFormatStyle.number.grouping(.never)` 关掉千位分隔符，避免显示 "1,000"。
        // 输入框右对齐 + 80pt 固定宽度，与其他「数字配置项」视觉对齐。
        autoTidyRow {
            LabeledContent {
                TextField(
                    "",
                    value: maxPerRunBinding,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .help("5 - 500")
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.maxPerRun",
                    description: "settings.autoTidy.range.maxPerRun.description"
                )
            }
        }
        Divider()
        autoTidyRow {
            Picker(selection: autoTidyBinding(\.sortOrder)) {
                ForEach(AutoTidySortOrder.allCases) { order in
                    Text(order.displayNameKey).tag(order)
                }
            } label: {
                autoTidyLabel(
                    title: "settings.autoTidy.range.sortOrder",
                    description: "settings.autoTidy.range.sortOrder.description"
                )
            }
            .pickerStyle(.menu)
        }
    }

    /// 仅收起标签参数；数量依然写入手动与自动整理共用的范围，阈值禁用条件保持不变。
    @ViewBuilder
    private var tagPolicyGroup: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                autoTidyLabel(
                    title: "settings.autoTidy.tagSuggestionCount",
                    description: "settings.autoTidy.tagSuggestionCount.description"
                )
                Spacer(minLength: 12)
                AITagSuggestionCountRangeControl(
                    minimum: settings.aiTagSuggestionMinCount,
                    maximum: settings.aiTagSuggestionMaxCount,
                    style: .regular
                ) { minimum, maximum in
                    settings.applyAITagSuggestionCounts(minimum: minimum, maximum: maximum)
                }
            }
        }
        .padding(.vertical, 8)
        Divider()

        // HOM-126 follow-up (dong4j 反馈 2026-06-07，截图：阈值 label 没有独立开关)：
        // 标签阈值区两层 disable：
        //   - 外层（整组）：标签关闭时整组 disable；
        //   - 内层（仅滑块）：`useConfidenceThreshold = false` → 阈值 Toggle 行还能点开，但滑块 disable，
        //     `makeBatchOptions` 把下游阈值降级为 0（不过滤，所有标签都自动应用）。
        Group {
            autoTidyRow {
                Toggle("settings.autoTidy.threshold.enabled", isOn: autoTidyBinding(\.useConfidenceThreshold))
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                SettingsSliderRow(
                    title: "settings.autoTidy.threshold.label",
                    value: autoTidyBinding(\.confidenceThreshold), range: 0.5...1.0,
                    step: 0.05, readout: thresholdPercentString
                )
                Text(String(format: String.l10n("settings.autoTidy.threshold.hintFormat"), thresholdPercentString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .disabled(!settings.autoTidySettings.useConfidenceThreshold)
            .opacity(settings.autoTidySettings.useConfidenceThreshold ? 1.0 : 0.5)
        }
    }

    /// 保留真实调度进度、上次结果与右对齐操作；仍需先开总开关，且不能在运行中重复触发。
    @ViewBuilder
    private var statusGroup: some View {
        Divider()

        // 备注与执行按钮同排；长译文可截断并通过提示查看，优先保证按钮完整可见。
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(lastRunSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Text(lastRunSummaryText))

            Spacer(minLength: 12)

            if autoTidyScheduler.isAutoTidyRunning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: autoTidyScheduler.autoTidyProgressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                autoTidyScheduler.triggerManually()
            } label: {
                Text("settings.automation.triggerNow")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize()
            // 已经在跑就 disable，避免重复触发；调度器内部也有 `batchService.isRunning` 检查兜底
            .disabled(autoTidyScheduler.isAutoTidyRunning || !settings.autoTidySettings.hasAnyAction)
        }
        .padding(.vertical, 8)
    }

    /// 「上次自动跑：X 分钟前 · 应用 12 / 忽略 3 / 失败 1」。
    /// 没有记录时给"尚未运行"文案。
    private var lastRunSummaryText: String {
        guard let last = settings.autoTidySettings.lastRunAt,
              let stats = settings.autoTidySettings.lastRunStats else {
            return String.l10n("settings.autoTidy.status.neverRun")
        }
        let timeAgo = RelativeTimeText.pastEvent(last, locale: locale)
        return String(
            format: String.l10n("settings.autoTidy.status.lastRunFormat"),
            timeAgo, stats.applied, stats.ignored, stats.failed
        )
    }

    private var thresholdPercentString: String {
        settings.autoTidySettings.confidenceThreshold.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    /// 仓库分组拥有独立阈值，不能与标签自动应用共用同一显示值。
    private var githubListGroupingThresholdPercentString: String {
        settings.githubStarListAutoGroupingSettings.confidenceThreshold.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    /// 摘要只读取现有配置；关闭过滤时仍保留阈值，不能为简化显示而改写真实设置。
    private var tagPolicySummary: String {
        let count = String(
            format: String.l10n("settings.automation.tagPolicy.rangeFormat"),
            settings.aiTagSuggestionMinCount.formatted(.number.locale(locale)),
            settings.aiTagSuggestionMaxCount.formatted(.number.locale(locale))
        )
        let policy = settings.autoTidySettings.useConfidenceThreshold
            ? String(format: String.l10n("settings.automation.tagPolicy.thresholdFormat"), thresholdPercentString)
            : String.l10n("settings.automation.tagPolicy.unfiltered")
        let parts = settings.autoTidySettings.generateTags
            ? [count, policy]
            : [String.l10n("settings.automation.tagPolicy.disabled"), count, policy]
        return parts.joined(separator: " · ")
    }

    private var autoTidyRulesSummary: String {
        let tidy = settings.autoTidySettings
        return automationRulesSummary(
            onLaunch: tidy.triggerOnLaunch, onSync: tidy.triggerOnSync,
            scheduled: tidy.triggerScheduled, hours: tidy.scheduledIntervalHours, count: tidy.maxPerRun
        )
    }

    private var listGroupingRulesSummary: String {
        let grouping = settings.githubStarListAutoGroupingSettings
        return automationRulesSummary(
            onLaunch: grouping.triggerOnLaunch, onSync: grouping.triggerOnSync,
            scheduled: grouping.triggerScheduled, hours: grouping.scheduledIntervalHours, count: grouping.maxPerRun
        )
    }

    /// 两组规则复用展示格式，数据仍分别来自各自配置；数字显式跟随应用 locale。
    private func automationRulesSummary(
        onLaunch: Bool, onSync: Bool, scheduled: Bool, hours: Int, count: Int
    ) -> String {
        var parts: [String] = []
        if onLaunch { parts.append(String.l10n("settings.automation.rules.launch")) }
        if onSync { parts.append(String.l10n("settings.automation.rules.sync")) }
        if scheduled {
            parts.append(String(
                format: String.l10n("settings.automation.rules.intervalFormat"),
                hours.formatted(.number.locale(locale))
            ))
        }
        if parts.isEmpty { parts.append(String.l10n("settings.automation.rules.none")) }
        parts.append(String(
            format: String.l10n("settings.automation.rules.batchFormat"),
            count.formatted(.number.locale(locale))
        ))
        return parts.joined(separator: " · ")
    }

    // MARK: - Auto Tidy Bindings

    /// 通用 binding helper：把 `AutoTidySettings` 的某个 keyPath 绑成可写 Binding。
    /// 写入时整段 settings 重新赋值，触发 `AppSettings.autoTidySettings.didSet` 持久化。
    private func autoTidyBinding<T>(_ keyPath: WritableKeyPath<AutoTidySettings, T>) -> Binding<T> {
        return Binding(
            get: { self.settings.autoTidySettings[keyPath: keyPath] },
            set: { newValue in
                var s = self.settings.autoTidySettings
                s[keyPath: keyPath] = newValue
                self.settings.autoTidySettings = s
            }
        )
    }

    /// GitHub Lists 自动分组使用独立 settings/key，不能借用标签分类的 Binding helper。
    private func githubListGroupingBinding<T>(
        _ keyPath: WritableKeyPath<GitHubStarListAutoGroupingSettings, T>
    ) -> Binding<T> {
        Binding(
            get: { self.settings.githubStarListAutoGroupingSettings[keyPath: keyPath] },
            set: { newValue in
                var grouping = self.settings.githubStarListAutoGroupingSettings
                grouping[keyPath: keyPath] = newValue
                self.settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }

    /// 数字输入仍 clamp 到原来的 5...500，不因配置行移入折叠区而放宽范围。
    private var maxPerRunBinding: Binding<Int> {
        Binding(
            get: { self.settings.autoTidySettings.maxPerRun },
            set: { newValue in
                let clamped = max(5, min(500, newValue))
                var s = self.settings.autoTidySettings
                s.maxPerRun = clamped
                self.settings.autoTidySettings = s
            }
        )
    }

    /// 定期间隔（小时）binding：clamp 到 `AutoTidySettings.scheduledIntervalHoursRange`。
    private var scheduledIntervalHoursBinding: Binding<Int> {
        Binding(
            get: { self.settings.autoTidySettings.scheduledIntervalHours },
            set: { newValue in
                var s = self.settings.autoTidySettings
                s.scheduledIntervalHours = AutoTidySettings.clampScheduledIntervalHours(newValue)
                self.settings.autoTidySettings = s
            }
        )
    }

    private var githubListGroupingMaxPerRunBinding: Binding<Int> {
        Binding(
            get: { self.settings.githubStarListAutoGroupingSettings.maxPerRun },
            set: { newValue in
                var grouping = self.settings.githubStarListAutoGroupingSettings
                grouping.maxPerRun = GitHubStarListAutoGroupingSettings.clampMaxPerRun(newValue)
                self.settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }

    private var githubListGroupingScheduledIntervalHoursBinding: Binding<Int> {
        Binding(
            get: { self.settings.githubStarListAutoGroupingSettings.scheduledIntervalHours },
            set: { newValue in
                var grouping = self.settings.githubStarListAutoGroupingSettings
                grouping.scheduledIntervalHours =
                    GitHubStarListAutoGroupingSettings.clampScheduledIntervalHours(newValue)
                self.settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }

    // MARK: - Actions

    /// 写入 `selectedProfileID` 的统一入口。
    /// nil → 持久化层写空串哨兵；非 nil → 直接写入 ID。
    /// 集中走这个 helper 是为了让"空串 ↔ nil"语义不要散落到 4 个赋值点。
    private func setSelectedProfileID(_ id: String?) {
        AppLog.ai.debug("[AISettings] setSelectedProfileID(\(id ?? "nil", privacy: .public)) prev=\(self.settings.aiSettingsSelectedProfileID, privacy: .public)")
        settings.aiSettingsSelectedProfileID = id ?? ""
    }

    private func ensureSelection() {
        if selectedProfileID == nil || pickerProfiles.allSatisfy({ $0.id != selectedProfileID }) {
            // 从未选过 / 指向已删 profile 时优先回落到本地 AI（首启动默认服务商）。
            let fallback = pickerProfiles.first(where: { $0.provider == .localAI })?.id
                ?? pickerProfiles.first?.id
            setSelectedProfileID(fallback)
        }
    }

    private func loadAPIKeys() {
        for profile in settings.aiProviderProfiles {
            apiKeys[profile.id] = (try? KeychainManager.shared.loadAIKey(forProvider: profile.id)) ?? ""
        }
    }

    @MainActor
    private func beginCCSwitchImport() {
        ccSwitchImportError = nil
        if DistributionChannel.current.isDirect,
           let url = POSIXHome.ccSwitchDefaultDatabase,
           FileManager.default.isReadableFile(atPath: url.path) {
            openCCSwitchFile(url)
            return
        }
        presentCCSwitchOpenPanel()
    }

    @MainActor
    private func presentCCSwitchOpenPanel() {
        let panel = NSOpenPanel()
        let defaultPath = POSIXHome.ccSwitchDefaultDatabase?.path ?? "~/.cc-switch/cc-switch.db"
        panel.message = String(format: String.l10n("settings.ai.provider.importCCSwitch.panelMessage"), defaultPath)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "db"),
            UTType(filenameExtension: "sqlite"),
            UTType(filenameExtension: "sqlite3"),
            UTType(filenameExtension: "sql")
        ].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCCSwitchFile(url)
    }

    @MainActor
    private func openCCSwitchFile(_ url: URL) {
        do {
            let rows = try CCSwitchConfigStore.open(url: url)
            let preview = CCSwitchProviderMapper.preview(
                rows: rows,
                sourcePath: url.path,
                anthropicAvailable: CCSwitchProviderMapper.isAnthropicAdapterAvailable
            )
            ccSwitchImportSession = CCSwitchImportSession(preview: preview)
        } catch {
            ccSwitchImportError = error.localizedDescription
        }
    }

    @MainActor
    private func importCCSwitchCandidates(
        _ candidates: [CCSwitchImportCandidate],
        progress: @MainActor (Int, Int, String) -> Void
    ) async -> CCSwitchImportOutcome {
        var succeeded: [CCSwitchImportResultRow] = []
        var failed: [CCSwitchImportResultRow] = []
        var existingNames = settings.aiProviderProfiles.map(\.displayName)
        var cancelled = false

        for (offset, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            progress(offset + 1, candidates.count, candidate.displayName)
            let displayName = CCSwitchProviderMapper.uniquedDisplayName(
                candidate.displayName,
                existing: existingNames
            )
            existingNames.append(displayName)
            let profile = AIProviderProfile(
                id: UUID().uuidString,
                provider: candidate.provider,
                displayName: displayName,
                baseURL: candidate.baseURL,
                isEnabled: false,
                lastTestStatus: .notTested
            )
            var profiles = settings.aiProviderProfiles
            profiles.append(profile)
            settings.aiProviderProfiles = profiles
            do {
                try persistAPIKey(
                    candidate.apiKey,
                    forProvider: profile.id,
                    allowsEmpty: profile.provider.allowsEmptyAPIKey
                )
                apiKeys[profile.id] = candidate.apiKey
            } catch {
                failed.append(CCSwitchImportResultRow(
                    id: profile.id,
                    displayName: displayName,
                    profileID: profile.id,
                    succeeded: false,
                    statusText: error.localizedDescription
                ))
                AppLog.ai.error("CC Switch import persist failed appType=\(candidate.appType, privacy: .public) provider=\(candidate.provider.rawValue, privacy: .public)")
                continue
            }

            await testAndFetchModels(profile)
            let updated = settings.aiProviderProfiles.first { $0.id == profile.id } ?? profile
            let ok: Bool
            if case .success = updated.lastTestStatus {
                ok = true
            } else {
                ok = false
            }
            let row = CCSwitchImportResultRow(
                id: profile.id,
                displayName: displayName,
                profileID: profile.id,
                succeeded: ok,
                statusText: updated.lastTestStatus.displayText
            )
            if ok {
                succeeded.append(row)
            } else {
                failed.append(row)
            }
            AppLog.ai.info("CC Switch import appType=\(candidate.appType, privacy: .public) provider=\(candidate.provider.rawValue, privacy: .public) success=\(ok, privacy: .public)")
        }

        if Task.isCancelled {
            cancelled = true
        }
        return CCSwitchImportOutcome(succeeded: succeeded, failed: failed, cancelled: cancelled)
    }

    @MainActor
    private func testAndFetchModels(_ profile: AIProviderProfile) async {
        isTestingProfileID = profile.id
        defer { isTestingProfileID = nil }

        let testingKey = apiKey(for: profile)
        do {
            let verified = try await providerConnectionTest.verify(
                profile: profile,
                apiKey: testingKey,
                referencedModelNames: referencedModelNames(for: profile.id)
            )
            try Task.checkCancellation()

            try persistAPIKey(testingKey, forProvider: profile.id, allowsEmpty: profile.provider.allowsEmptyAPIKey)

            updateProfile(profile.id) { current in
                current = verified
            }
            apiKeys[profile.id] = testingKey
            repairTasksAfterProfileChange()
        } catch {
            // 退场取消不属于连接失败，不能在页面关闭后写入失败记录。
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            updateProfile(profile.id) { current in
                current.lastTestedAt = ISO8601DateFormatter.shared.string(from: Date())
                current.lastTestStatus = .failed(error.localizedDescription)
            }
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

    private func apiKey(for profile: AIProviderProfile) -> String {
        apiKeys[profile.id, default: ""]
    }

    private func restoreDefaultPrompt(_ task: AIModelTask) {
        // 2026-09-11：翻译任务的 Prompt（分段 / 全文）已迁入「翻译服务」设置页，
        // 这里只剩非翻译任务的恢复默认；`.translation` 分支仅为 switch 穷尽性保留。
        updateTask(task) { config in
            switch task {
            case .summary:
                config.prompt = AIDefaultPrompts.summary
            case .tags:
                config.prompt = AIDefaultPrompts.tags
            case .embedding:
                config.prompt = AIDefaultPrompts.embedding
            case .chat:
                config.prompt = AIDefaultPrompts.chat
            case .translation:
                // UI 不再出现翻译任务（已迁「翻译服务」页）；仅为穷尽性保留。
                config.prompt = AIDefaultPrompts.translation
            }
        }
    }

    // MARK: - Bindings

    private var selectedProfileBinding: Binding<String?> {
        Binding(
            get: { selectedProfileID },
            set: { newSelection in
                // Picker 刷新可能回写 nil 或同值；只有真正选择另一项才持久化。
                guard let newSelection, newSelection != selectedProfileID else { return }
                setSelectedProfileID(newSelection)
            }
        )
    }

    private func modelEnabledBinding(_ profileID: String, _ modelID: String) -> Binding<Bool> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.isEnabled ?? false },
            set: { enabled in
                // 取消勾选前先记下是否被任务引用：未引用时不必跑 repair（会连写 5 份 task JSON）。
                guard model(profileID: profileID, modelID: modelID)?.isEnabled != enabled else { return }
                let modelName = model(profileID: profileID, modelID: modelID)?.name
                let needsTaskRepair = !enabled && isModelReferencedByAnyTask(
                    providerID: profileID,
                    modelName: modelName
                )
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.isEnabled = enabled
                }
                if needsTaskRepair {
                    repairTasksAfterProfileChange()
                }
            }
        )
    }

    /// 任一任务是否正指向该 provider + 模型（自定义模型名不算「目录勾选」引用）。
    private func isModelReferencedByAnyTask(providerID: String, modelName: String?) -> Bool {
        guard let modelName, !modelName.isEmpty else { return false }
        return AIModelTask.allCases.contains { task in
            let config = taskConfig(task)
            guard config.providerID == providerID, !config.useCustomModel else { return false }
            return config.modelID == modelName
        }
    }

    /// 合并 / 消毒大目录时保住任务仍在用的模型名（含自定义名称，避免关掉正在跑的配置）。
    private func referencedModelNames(for profileID: String) -> Set<String> {
        Set(AIModelTask.allCases.compactMap { task in
            let config = taskConfig(task)
            guard config.providerID == profileID else { return nil }
            let name = config.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
    }

    private func modelCapabilityBinding(_ profileID: String, _ modelID: String) -> Binding<AIModelCapability> {
        Binding(
            get: { model(profileID: profileID, modelID: modelID)?.capability ?? .unknown },
            set: { capability in
                // Picker 出现时可能把当前值再 set 一遍；无变化就不要写回整个 profiles 数组。
                guard model(profileID: profileID, modelID: modelID)?.capability != capability else { return }
                updateModel(profileID: profileID, modelID: modelID) { model in
                    model.capability = capability
                }
                repairTasksAfterProfileChange()
            }
        )
    }

    /// 菜单身份同时包含服务商和模型；自定义项与不可用项只用于显示当前值。
    private func taskModelChoice(_ task: AIModelTask) -> TaskModelChoice {
        let config = taskConfig(task)
        return TaskModelChoice(
            providerID: config.providerID,
            modelName: config.useCustomModel ? config.customModelName : config.modelID,
            isCustom: config.useCustomModel
        )
    }

    /// 合并下拉的一次选择等价于原先先选服务商再选模型，但只写入一次任务配置。
    private func taskModelChoiceBinding(_ task: AIModelTask) -> Binding<TaskModelChoice> {
        Binding(
            get: { taskModelChoice(task) },
            set: { choice in
                guard !choice.isCustom,
                      eligibleVerifiedProfiles(for: task).contains(where: { $0.id == choice.providerID }),
                      enabledModels(providerID: choice.providerID, capability: task.requiredCapability)
                        .contains(where: { $0.name == choice.modelName }) else { return }
                settings.selectLocalAIModel(named: choice.modelName, providerID: choice.providerID)
                updateTask(task) { config in
                    if config.providerID != choice.providerID,
                       let first = enabledModels(providerID: choice.providerID, capability: task.requiredCapability).first {
                        // 原服务商切换会预填首个模型名称；同服务商切换仍保留手填文本。
                        config.customModelName = first.name
                    }
                    config.providerID = choice.providerID
                    config.modelID = choice.modelName
                    config.useCustomModel = false
                }
            }
        )
    }

    private func taskCustomEnabledBinding(_ task: AIModelTask) -> Binding<Bool> {
        Binding(
            get: { taskConfig(task).useCustomModel },
            set: { enabled in
                updateTask(task) { config in
                    config.useCustomModel = enabled
                    // 仅「开启且输入为空」时用当前列表模型预填；关闭开关绝不清空文本。
                    if enabled, config.customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        config.customModelName = config.modelID
                    }
                }
            }
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

    // 2026-09-11：翻译 Prompt（分段 / 全文）的编辑入口已迁入「翻译服务」设置页，
    // 这里的 binding 只服务其余任务。
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

    /// 服务商 Picker 的可选项：已验证 profile + 内置本地 AI（未下载模型时也显示，
    /// 选中后由「本地 AI 模型」区引导下载）。首启动默认选中 Local AI（dong4j 2026-09-12）。
    private var pickerProfiles: [AIProviderProfile] {
        settings.aiProviderProfiles.filter { $0.isVerifiedConfiguration || $0.provider == .localAI }
    }

    /// 任务下拉只显示具备对应协议端点的已验证 Provider。
    ///
    /// 模型 capability 来自名称推断或用户标注，不能替代 Provider 端点能力；尤其
    /// OrcaRouter 的 `/v1/models` 会返回 Chat/多媒体模型，但没有 `/v1/embeddings`。
    private func eligibleVerifiedProfiles(for task: AIModelTask) -> [AIProviderProfile] {
        verifiedProfiles.filter { profile in
            task.requiredCapability != .embedding || profile.provider.supportsEmbeddingEndpoint
        }
    }

    private var activeProfile: AIProviderProfile? {
        selectedProfile
    }

    private var selectedProfile: AIProviderProfile? {
        guard let selectedProfileID else { return pickerProfiles.first }
        return pickerProfiles.first { $0.id == selectedProfileID }
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
        let config: AIModelTaskConfiguration
        switch task {
        case .summary:     config = settings.aiSummaryTask
        case .tags:        config = settings.aiTagsTask
        case .embedding:   config = settings.aiEmbeddingTask
        case .translation: config = settings.aiTranslationTask
        case .chat:        config = settings.aiChatTask
        }
        return settings.resolvedAITask(config, type: task.requiredCapability == .embedding ? .embedding : .llm)
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
        case .chat:
            settings.aiChatTask = config
        }
    }

    // 统一菜单仍逐服务商过滤，选择身份使用 TaskModelChoice，避免跨服务商同名模型串选。
    private func enabledModels(providerID: String, capability: AIModelCapability) -> [AIModelDescriptor] {
        guard let profile = profile(providerID), profile.isVerifiedConfiguration else { return [] }
        guard capability != .embedding || profile.provider.supportsEmbeddingEndpoint else { return [] }
        return profile.models.filter {
            $0.isEnabled && ($0.capability == capability || $0.capability == .unknown)
        }
    }

    private func repairTasksAfterProfileChange() {
        for task in AIModelTask.allCases {
            let config = taskConfig(task)
            // 明确选中的本地模型未下载/已卸载时应提示安装，不能静默换成远程服务商。
            if profile(config.providerID)?.provider == .localAI { continue }
            let models = enabledModels(providerID: config.providerID, capability: task.requiredCapability)
            let eligibleProfiles = eligibleVerifiedProfiles(for: task)
            let currentProfileIsEligible = eligibleProfiles.contains { $0.id == config.providerID }
            if !currentProfileIsEligible || (!config.useCustomModel && models.allSatisfy { $0.name != config.modelID }) {
                let fallbackProfile = eligibleProfiles.first
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

}

#Preview {
    AISettingsTab()
        .environment(AppSettings(defaults: .standard))
        .frame(width: 720, height: 860)
}

/// Provider 配置区专用单行输入框。
///
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

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? ListenerView else { return }
        view.onClose = nil
        view.removeObserver()
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
                // queue 已固定为 main；同步失效新增会话，防止排队的网络成功回调抢先保存。
                MainActor.assumeIsolated {
                    self?.onClose?()
                }
            }
        }

        @MainActor
        fileprivate func removeObserver() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }
    }
}
