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
    /// HOM-126：「立刻手动触发一次」按钮直接调度。@Environment 注入自 StarcatApp。
    @Environment(AutoTidyScheduler.self) private var autoTidyScheduler
    /// 2026-06-12 向量索引改进：AI 索引 Section 的"开始 / 暂停 / 全量重建"按钮需要
    /// 直接调度 `SemanticIndexBuilder`。从 AppDependencies 拿。
    @Environment(AppDependencies.self) private var dependencies
    /// 2026-06-15:disclosureLabel / 草稿 Provider 收/放 / 已发现模型展开等
    /// 多处 0.18-0.2s 动画在「关闭应用内动画」时跳过。
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

    /// HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
    /// 删除服务商需要二次确认。删除会同步删 profile + Keychain key + 修复
    /// 任务绑定（`repairTasksAfterProfileChange`），属于不可逆破坏性操作，
    /// 走 `.confirmationDialog` 拦一道。`pendingDeleteProfileID` 持有待删
    /// 目标的 ID 而非整个 profile，避免 dialog 弹起期间 `verifiedProfiles`
    /// 数组变化导致引用悬空（异步刷新 / @AppStorage 写回都可能触发刷新）。
    @State private var pendingDeleteProfileID: String?

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
    /// 「自动整理」分组的展开偏好。默认折叠——与同 Tab 内其他 DisclosureGroup
    /// （已发现模型 / 模型配置 / Prompt / AI 索引 / AI 代码上下文）的默认折叠风格统一，
    /// 避免设置页一进来一堆分组同时展开造成视觉拥挤；用户主动展开后由 SceneStorage 持久化。
    @SceneStorage("settings.ai.autoTidy.expanded") private var isAutoTidyExpanded: Bool = false

    /// 2026-06-12 向量索引改进："AI 索引"分组默认收起，避免设置页一进来 6 个分组太挤；
    /// 用户主动点开后偏好持久化。
    @SceneStorage("settings.ai.aiIndex.expanded") private var isAIIndexExpanded: Bool = false

    /// "AI 索引"折叠区显示 / 隐藏具体阈值数字；预设 == `.custom` 时强制展开（写 didSet 上不易，
    /// 这里通过 computed `effectiveAdvancedExpanded` 处理）。
    @SceneStorage("settings.ai.aiIndex.advancedExpanded") private var isAIIndexAdvancedExpanded: Bool = false

    /// 2026-06-13 RepoContextPacker 客户端接入（§0.4 Y3）：「AI 代码上下文」分组的展开偏好。
    /// 默认收起——与 promptSection / aiIndexSection 一致；避免设置页首次打开就被新 section 撑高。
    /// 用户主动点开后偏好持久化（SceneStorage 跨设置窗口打开周期保留）。
    @SceneStorage("settings.ai.repoContext.expanded") private var isRepoContextExpanded: Bool = false

    /// HOM-68 v3 (2026-06-15)：AI 代码上下文产物管理面板从存储 Tab 搬过来。
    /// `@Observable` 单例直接订阅；视图层调 reveal / delete 等方法时由 storage 内部
    /// 处理 security scope。
    @State private var aiContextStorage = RepoContextStorage.shared

    /// AI 代码上下文 storage 操作失败时弹 alert 用。和 `keyError` 等并列各管一摊。
    @State private var aiContextActionError: String?

    /// "全量重建"二次确认。
    @State private var pendingRebuildAllConfirm: Bool = false

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
            // HOM-126 follow-up (dong4j 反馈 2026-06-07)：
            // 自动整理分类放到 Prompt 之后——按"配置链路从上到下"顺序排：
            // Provider → 模型 → 模型配置 → Prompt → 自动化（消费上面所有配置）→ 隐私说明。
            autoTidySection
            // 2026-06-12 向量索引改进：AI 索引（向量化）配置，放在自动整理之后
            // 因为索引依赖摘要 / README 等上游配置就绪。
            aiIndexSection
            // 2026-06-13 RepoContextPacker 客户端接入（§0.4 Y3）：AI 代码上下文配置。
            // 放在 aiIndexSection 与 privacySection 之间——与「索引」性质相同（消费上游配置的
            // 高级 AI 能力），且紧贴 privacySection 形成「先看功能再看隐私」的阅读节奏。
            aiRepoContextSection
            privacySection
        }
        .confirmationDialog(
            String.l10n("settings.aiIndex.rebuildAll.confirmTitle"),
            isPresented: $pendingRebuildAllConfirm,
            titleVisibility: .visible
        ) {
            Button(String.l10n("settings.aiIndex.rebuildAll.confirm"), role: .destructive) {
                dependencies.semanticIndexBuilder.rebuildAll()
            }
            Button(String.l10n("general.cancel"), role: .cancel) {}
        } message: {
            Text("settings.aiIndex.rebuildAll.confirmMessage")
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
        // HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12 (dong4j 反馈)：
        // 删除服务商二次确认。用 `presenting:` 把 profile 注入到 dialog 闭包，
        // 让按钮标题能显示具体服务商名（"删除「DeepSeek」"），减少误删风险。
        // 用 `pendingDeleteProfileID` 而非整个 profile 作为状态源，避免数组刷新
        // 期间引用悬空（见 `pendingDeleteProfileID` 注释）。
        .confirmationDialog(
            "settings.ai.provider.deleteConfirm.title",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingDeleteProfile
        ) { profile in
            Button(role: .destructive) {
                deleteProfile(id: profile.id)
            } label: {
                Text("settings.ai.provider.deleteConfirm.confirmFormat \(profile.displayName)")
            }
            Button("settings.common.cancel", role: .cancel) {
                pendingDeleteProfileID = nil
            }
        } message: { profile in
            Text("settings.ai.provider.deleteConfirm.messageFormat \(profile.displayName)")
        }
        // HOM-68 v3 (2026-06-15)：AI 代码上下文产物管理从存储 Tab 搬过来后,
        // 进入 AI Tab 时强制重扫描产物目录,让用户刚生成的产物立即可见。
        .task {
            aiContextStorage.reload()
        }
        // AI 代码上下文 storage 操作失败 alert (与 IntegrationSettingsView 同款模式)。
        .alert(
            "ai.context.storage.actionFailed",
            isPresented: Binding(
                get: { aiContextActionError != nil },
                set: { if !$0 { aiContextActionError = nil } }
            )
        ) {
            Button("general.ok") { aiContextActionError = nil }
        } message: {
            Text(aiContextActionError ?? "")
        }
    }

    /// 二次确认 dialog 的 isPresented 绑定。
    /// set 时支持外部把它置 false（点 macOS 系统返回 / 点空白处关 dialog），
    /// 同步清掉 `pendingDeleteProfileID` 避免下次再弹时残留旧目标。
    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
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
            setSelectedProfileID(verifiedProfiles.first?.id)
        }
        repairTasksAfterProfileChange()
        pendingDeleteProfileID = nil
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
                    // HOM-AIPROVIDERS-HIDE-PROVIDER-2026-06-12 (dong4j 反馈)：
                    // zero state 文案补充行动指引——之前只说「暂无已验证服务商」是
                    // 状态描述，用户不知道下一步要做什么。改成「...点右侧 + 新增」
                    // 让新用户直接看到入口。
                    Text("settings.ai.provider.empty")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("settings.ai.provider.pickerLabel", selection: selectedProfileBinding) {
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
                    // HOM-AIPROVIDERS-HIDE-PROVIDER-2026-06-12：包 withAnimation 让下方
                    // Provider 行 + 输入区伴随 transition 滑入，而不是瞬切。
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        beginDraft(provider: .openAICompatible)
                    }
                } label: {
                    Label("settings.ai.provider.add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("settings.ai.provider.addHelp")
                .disabled(draftProfile != nil)

                Button(role: .destructive) {
                    // HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12：先弹二次确认 dialog，
                    // dialog 内点「删除」才真正执行 `deleteProfile(id:)`。
                    pendingDeleteProfileID = selectedProfileID
                } label: {
                    Label("settings.ai.provider.delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("settings.ai.provider.deleteHelp")
                .disabled(selectedProfile == nil)
            }

            // HOM-AIPROVIDERS-HIDE-PROVIDER-2026-06-12 (dong4j 反馈)：
            // Provider 下拉只在「点 + 进入新增草稿」时显示。背景：之前两个下拉常驻
            //   1) 「服务商配置」= 已验证 profile 切换
            //   2) 「Provider」    = 选 provider 类型 / 隐式重建草稿
            // 两个下拉语义不同但视觉同形（都是 menu picker），新用户进设置页一眼看
            // 不出谁是「我现在在看哪个 profile」、谁是「我要新建」。更糟的是 Provider
            // 下拉直接切类型就会重建草稿（`supportedProviderBinding.set` 调
            // `beginDraft`），与右上角 `+` 按钮形成两个新增入口，违反「+ 是新增唯一
            // 入口」的产品意图。
            //
            // 修法：Provider 下拉用 `if draftProfile != nil` 包裹，常态隐藏；只在点
            // `+`（→ beginDraft → draftProfile != nil）后随输入区一起出现。这样信息
            // 架构变成「常态只显示当前 profile / 点 + 进入新增模式才显示类型选择」，
            // 与 macOS 系统设置「网络 → +」的交互节奏一致。
            //
            // Provider 切换仍走原 `supportedProviderBinding`（重建草稿，丢弃同一草稿
            // 内已输入的 displayName/baseURL/apiKey）。这是合理的——切类型本质就是
            // 「换底子」，不同 provider 的默认 baseURL 完全不同，保留旧值会更困惑。
            //
            // transition 用 `.opacity` + 默认 spring，让出现/消失自然过渡，避免 Form
            // 里某行突然蹦出来。
            //
            // 边界场景：用户在已验证 profile 上修改 displayName/baseURL/apiKey 时，
            // `editableProfileTextBinding` 会调 `beginDraft(from: current)` 把它提升为
            // 草稿 → 这里 Provider 行也会跟着出现。这是预期行为：① 与「新增模式」UI
            // 统一（draft != nil 都显示）；② 用户编辑时本来就可以切类型（如发现 Base
            // URL 错了想换个 provider），保留这个能力；③ 用户不点 Provider 就不会
            // 影响输入，干扰极小。
            if draftProfile != nil {
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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

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
                                Text("settings.ai.provider.testButton")
                            }
                        } else {
                            Label("settings.ai.provider.testButton", systemImage: "network")
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
            Text("settings.ai.provider.sectionTitle")
        } footer: {
            Text("settings.ai.provider.sectionFooter")
        }
    }

    private var enabledModelsSection: some View {
        // HOM-68 follow-up v7 (dong4j 反馈 2026-06-05 23:20)：
        // 改成 DisclosureGroup 默认折叠，与"模型参数" / "Prompt" 折叠风格统一。
        // 自动展开时机：用户点"测试并获取模型"成功且 ≥1 个模型时，自动 expand
        // 一次（见 `testAndFetchModels`），让"配置 → 测试 → 看模型"的完整路径
        // 不需要手动展开折叠组。
        //
        // HOM-126 follow-up (dong4j 反馈 2026-06-07)：折叠组内层加 VStack(spacing: 14) 收紧
        // 上下内边距与「模型配置」/「Prompt」一致——折叠组展开后视觉对齐。
        Section {
            DisclosureGroup(isExpanded: $isDiscoveredModelsExpanded) {
                VStack(spacing: 14) {
                    if let profile = selectedProfile {
                        if profile.models.isEmpty {
                            Text("settings.ai.discoveredModels.empty")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            AIModelListView(
                                profile: profile,
                                enabledBinding: { model in modelEnabledBinding(profile.id, model.id) },
                                capabilityBinding: { model in modelCapabilityBinding(profile.id, model.id) },
                                parametersBinding: { model in modelParametersBinding(profile.id, model.id) }
                            )
                        }
                    }
                }
            } label: {
                disclosureLabel("settings.ai.discoveredModels.title", isExpanded: $isDiscoveredModelsExpanded)
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
                    Picker("settings.ai.task.pickerLabel", selection: $taskModelTask) {
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
                disclosureLabel("settings.ai.taskModels.title", isExpanded: $isTaskModelsExpanded)
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

                Picker("settings.ai.task.modelLabel", selection: taskModelBinding(task)) {
                    if availableModels.isEmpty {
                        Text("settings.ai.task.noAvailableModel")
                            .tag("")
                    } else {
                        ForEach(availableModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Toggle("settings.ai.task.customToggle", isOn: taskCustomEnabledBinding(task))
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }

            if taskConfig(task).useCustomModel {
                TextField("settings.ai.task.customModelPlaceholder", text: taskCustomModelBinding(task))
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
            providerInputRow(label: "settings.ai.provider.displayName", labelWidth: labelWidth, columnSpacing: columnSpacing, rowHeight: rowHeight) {
                ProviderSingleLineTextField(text: editableProfileTextBinding(keyPath: \.displayName))
                    .accessibilityLabel("settings.ai.provider.displayName")
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
    private func disclosureLabel(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(titleKey)
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

    // MARK: - Auto Tidy (HOM-126)

    /// HOM-126：「自动整理」分组。
    ///
    /// 设计：
    /// - 用 DisclosureGroup 默认折叠（与同 Tab 其他折叠组统一），用户主动展开后由
    ///   `isAutoTidyExpanded` SceneStorage 持久化。
    /// - 总开关 OFF 时下面所有子项 `.disabled(true)` + `.opacity(0.5)`，符合 HOM-126
    ///   验收"总开关关闭时所有子项 disabled"。
    /// - 触发时机用三个独立 Toggle（启动 / 同步 / 定时），UI 简单直接；不用 Picker
    ///   是因为三者可同时开（"启动后跑一次 + 同步后增量 + 每天定时"）。
    /// - 处理范围用 Stepper（5...500，步进 5）+ 排序 Picker。
    /// - 阈值用 Slider（与 BatchAIOptionsSheet 的阈值滑条视觉一致），范围 0.5...1.0
    ///   步进 0.05；显示百分比。
    /// - 运行状态用只读 LabeledContent + 「立刻手动触发一次」按钮。
    private var autoTidySection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAutoTidyExpanded) {
                autoTidyContent
            } label: {
                disclosureLabel("settings.autoTidy.section", isExpanded: $isAutoTidyExpanded)
            }
        }
    }

    @ViewBuilder
    private var autoTidyContent: some View {
        // 总开关
        //
        // HOM-126 follow-up v2 (dong4j 反馈 2026-06-07，截图仍显示开关 thumb 被裁)：
        // v1 用 `LabeledContent { Toggle().labelsHidden() } label: { VStack { title + description } }`，
        // 两行 VStack label 把 row 撑高、把横向空间吃宽，macOS Form 仍把 trailing Toggle 挤到
        // Section 右内边距，`.switch` 的 thumb 圆点贴边被裁。dong4j 提示"往下移动一点"——
        // 真正的修法是：让 toggle 行只承载单行标题（让 toggle 有充足右侧空间），description
        // 独立作为下一行普通 Text 显示。这样开关就和「触发时机」下面那几个单行 toggle 一样
        // 自然右对齐、thumb 完整。
        Toggle("settings.autoTidy.enabled.title", isOn: autoTidyBinding(\.enabled))
            .toggleStyle(.switch)
        Text("settings.autoTidy.enabled.description")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

        // 子项总开关：用 group `.disabled(!enabled)` 一刀切，省去每个 Toggle 单独写
        Group {
            triggerGroup
            rangeGroup
            actionsGroup
            statusGroup
        }
        .disabled(!settings.autoTidySettings.enabled)
        // disabled 后整体淡化，给用户"这一段被锁住"的视觉信号
        .opacity(settings.autoTidySettings.enabled ? 1.0 : 0.5)
    }

    /// HOM-126 follow-up (dong4j 反馈 2026-06-07，截图："间距拥挤、不一致")：
    /// 共用的子分组标题样式 helper，统一垂直 padding（上 14 / 下 4）让 section header
    /// 与上下 row 之间有一致呼吸感。原本各 group 用 `Divider() + Text` 的写法让 Divider
    /// 自己占一行，反而让间距更不一致——SwiftUI Form 内 Divider 高度小、Toggle 行高度
    /// 大，混在一起视觉节奏跳。删 Divider 改用 `Text` + padding，所有分组间距统一。
    private func autoTidySectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    /// 触发时机：启动后延迟 / 同步后增量 / 定时 24h。
    @ViewBuilder
    private var triggerGroup: some View {
        autoTidySectionHeader("settings.autoTidy.triggers.label")

        Toggle("settings.autoTidy.trigger.onLaunch", isOn: autoTidyBinding(\.triggerOnLaunch))
        Toggle("settings.autoTidy.trigger.onSync", isOn: autoTidyBinding(\.triggerOnSync))
        Toggle("settings.autoTidy.trigger.scheduled", isOn: autoTidyBinding(\.triggerScheduled))
    }

    /// 处理范围：最多一次处理多少个 + 排序口径。
    @ViewBuilder
    private var rangeGroup: some View {
        autoTidySectionHeader("settings.autoTidy.range.label")

        // HOM-126 follow-up (dong4j 反馈 2026-06-07)：Stepper → TextField + 数字校验。
        // SwiftUI `TextField(value:format: .number)` 内置只接受数字输入（非数字字符被吃掉），
        // setter 在 `maxPerRunBinding` 内已 clamp 到 5...500，超范围 / 失焦后 binding 把值约束回区间。
        // 用 `IntegerFormatStyle.number.grouping(.never)` 关掉千位分隔符，避免显示 "1,000"。
        // 输入框右对齐 + 80pt 固定宽度，与其他「数字配置项」视觉对齐。
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
            Text("settings.autoTidy.range.maxPerRun")
        }

        Picker("settings.autoTidy.range.sortOrder", selection: autoTidyBinding(\.sortOrder)) {
            ForEach(AutoTidySortOrder.allCases) { order in
                Text(order.displayNameKey).tag(order)
            }
        }
        .pickerStyle(.menu)
    }

    /// 执行操作：摘要 / 标签 + 置信度阈值。
    @ViewBuilder
    private var actionsGroup: some View {
        autoTidySectionHeader("settings.autoTidy.actions.label")

        Toggle("settings.autoTidy.actions.generateTags", isOn: autoTidyBinding(\.generateTags))
        Toggle("settings.autoTidy.actions.generateSummary", isOn: autoTidyBinding(\.generateSummary))

        // HOM-126 follow-up (dong4j 反馈 2026-06-07，截图：阈值 label 没有独立开关)：
        // 阈值区两层 disable：
        //   - 外层（整组）：`generateTags = false` → 阈值 Toggle 和滑块全 disable（标签都关了阈值无意义）；
        //   - 内层（仅滑块）：`useConfidenceThreshold = false` → 阈值 Toggle 行还能点开，但滑块 disable，
        //     `makeBatchOptions` 把下游阈值降级为 0（不过滤，所有标签都自动应用）。
        // 用 `Group { ... }` 收住 Toggle + 滑块两个子视图，让外层 `.disabled(!generateTags)` 能同时作用于两者。
        Group {
            Toggle("settings.autoTidy.threshold.enabled", isOn: autoTidyBinding(\.useConfidenceThreshold))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("settings.autoTidy.threshold.label")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: thresholdPercentString)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
                Slider(value: autoTidyBinding(\.confidenceThreshold), in: 0.5...1.0, step: 0.05)
                    .controlSize(.mini)
                Text(String(format: String.l10n("settings.autoTidy.threshold.hintFormat"), thresholdPercentString))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.autoTidySettings.useConfidenceThreshold)
            .opacity(settings.autoTidySettings.useConfidenceThreshold ? 1.0 : 0.5)
        }
        .disabled(!settings.autoTidySettings.generateTags)
        .opacity(settings.autoTidySettings.generateTags ? 1.0 : 0.5)
    }

    /// 运行状态只读 + 手动触发按钮。
    /// 即使总开关关着，「立刻手动触发一次」也保持可点（用户可能想"现在跑一次试试效果再决定要不要开总开关"）。
    /// 但 disabled group 把这里也锁住了——为了避免特殊化处理破坏 disabled 整体语义，
    /// 我们干脆把状态区也放在 disabled 范围内；用户必须先开总开关才能手动触发。
    ///
    /// HOM-126 follow-up (dong4j 反馈 2026-06-07)：
    /// 整个状态卡片改右对齐——「运行状态」label、「上次自动跑 xxx」icon+text、
    /// 「立刻手动触发一次」按钮 + 运行进度文字，全部贴右侧。实现方式：在每行的
    /// HStack 开头放 `Spacer()`，把元素挤到右端；不再用 `.frame(maxWidth: .infinity,
    /// alignment: .leading)`。这样跟 dong4j 截图里 macOS Settings 标准右侧操作列
    /// 的视觉一致。
    @ViewBuilder
    private var statusGroup: some View {
        // 状态分组的 header 走右对齐而不是 left（与下面"上次自动跑/按钮"右对齐保持一致），
        // 所以不复用 autoTidySectionHeader（那个是 left + bottom padding 4）。
        HStack {
            Spacer()
            Text("settings.autoTidy.status.label")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 14)
        .padding(.bottom, 4)

        // 上次运行时间 + 计数（贴右对齐）
        HStack(spacing: 6) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(lastRunSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // 手动触发按钮 + 当前是否在跑的轻量提示（按钮贴右对齐）
        HStack(spacing: 8) {
            Spacer()
            if autoTidyScheduler.isAutoTidyRunning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(verbatim: autoTidyScheduler.autoTidyProgressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                autoTidyScheduler.triggerManually()
            } label: {
                Label("settings.autoTidy.triggerNow", systemImage: "play.fill")
            }
            // 已经在跑就 disable，避免重复触发；调度器内部也有 `batchService.isRunning` 检查兜底
            .disabled(autoTidyScheduler.isAutoTidyRunning || !settings.autoTidySettings.hasAnyAction)
        }
    }

    /// 「上次自动跑：X 分钟前 · 应用 12 / 忽略 3 / 失败 1」。
    /// 没有记录时给"尚未运行"文案。
    private var lastRunSummaryText: String {
        guard let last = settings.autoTidySettings.lastRunAt,
              let stats = settings.autoTidySettings.lastRunStats else {
            return String.l10n("settings.autoTidy.status.neverRun")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        let timeAgo = formatter.localizedString(for: last, relativeTo: Date())
        return String(
            format: String.l10n("settings.autoTidy.status.lastRunFormat"),
            timeAgo, stats.applied, stats.ignored, stats.failed
        )
    }

    private var thresholdPercentString: String {
        "\(Int((settings.autoTidySettings.confidenceThreshold * 100).rounded()))%"
    }

    // MARK: - Auto Tidy Bindings

    /// 通用 binding helper：把 `AutoTidySettings` 的某个 keyPath 绑成可写 Binding。
    /// 写入时整段 settings 重新赋值，触发 `AppSettings.autoTidySettings.didSet` 持久化。
    private func autoTidyBinding<T>(_ keyPath: WritableKeyPath<AutoTidySettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings.autoTidySettings[keyPath: keyPath] },
            set: { newValue in
                var s = self.settings.autoTidySettings
                s[keyPath: keyPath] = newValue
                self.settings.autoTidySettings = s
            }
        )
    }

    /// `maxPerRun` 的独立 binding：Stepper 已经限定 5...500，但 binding 仍 clamp 一道
    /// 防御性兜底（避免外部按钮 / 快捷键 / 程序化路径写入越界值）。
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
        // HOM-126 follow-up (dong4j 反馈 2026-06-07，"Prompt/模型配置/已发现模型 面板间距")：
        // 用 `VStack(spacing: 14)` 显式给开 14pt（与 `taskModelsSection` 同款），
        // 避免 Form 默认让 Text(header) → TextEditor → Text(header) → TextEditor 之间
        // 黏连。System/User Prompt 两组之间 14pt 是正合适的呼吸感（更大会显得空）。
        Section {
            DisclosureGroup(isExpanded: $isPromptExpanded) {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Picker("settings.ai.prompt.task.pickerLabel", selection: $promptTask) {
                            ForEach([AIModelTask.summary, .tags, .embedding, .translation]) { task in
                                Text(task.displayName).tag(task)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        // HOM-126 follow-up (dong4j 反馈 2026-06-07)：「恢复默认」按钮去掉文字只保留 icon
                        // （扫一眼就懂 = 旋转箭头），节省横向空间让左侧 segmented picker 不被挤；语义留在 tooltip。
                        Button {
                            restoreDefaultPrompt(promptTask)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .help(Text("settings.ai.prompt.restoreHelpFormat \(promptTask.displayName)"))
                    }

                    VStack(alignment: .leading, spacing: 6) {
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
                    }

                    VStack(alignment: .leading, spacing: 6) {
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
                    }

                    Text(promptPlaceholderHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } label: {
                disclosureLabel("settings.ai.prompt.title", isExpanded: $isPromptExpanded)
            }
        }
    }

    // MARK: - AI 索引（向量搜索改进 2026-06-12）

    /// "向量化索引" Section（原 "AI 索引"，HOM-197 2026-06-13 改名）：
    /// README 截断长度滑杆 + 搜索结果过滤阈值滑杆 + 三档阈值预设 + 折叠区精细数字 + 预拉 / 全量重建按钮。
    ///
    /// UI 形态：
    /// ```
    /// 向量化索引 ▼
    ///   ┌ README 截断长度 ──── 滑杆 [12000] ──── 12000 字符
    ///   ├ 搜索结果过滤阈值 ─── 滑杆 [75%] ────── 75%      ← HOM-197 新增
    ///   ├ 阈值预设      ── 严格 / 标准 / 宽松 / 自定义
    ///   ├ 高级（折叠）  ── 主体阈值 Slider + 笔记阈值 Slider   ← HOM-197 Stepper→Slider
    ///   ├ ─────────────────────
    ///   ├ 启动自动预拉 [开关]
    ///   ├ [开始预拉] [暂停]     进度 234 / 1801（失败 0）
    ///   └ [⚠ 全量重建]
    /// ```
    ///
    /// 切换预设时通过 `applyAIIndexPreset(_:)` 把 body / notes 具体数字同步过去，避免
    /// 折叠区显示 10/20 但实际生效 5/10 的"漂移"。
    private var aiIndexSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAIIndexExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    truncateLengthRow
                    // HOM-197（2026-06-13 dong4j）：紧贴截断长度下方插入「搜索结果过滤
                    // 阈值」。两者都属于"AI 语义搜索流水线"维度的偏好——截断长度控制
                    // 喂给 embedding 的文本量，阈值控制召回结果的展示门槛，放在一起
                    // 让用户一眼读出"输入→输出"两端的旋钮。
                    scoreThresholdRow
                    presetRow
                    advancedDisclosure
                    Divider()
                    Toggle("settings.aiIndex.autoPrefetch", isOn: autoPrefetchBinding)
                    builderControlsRow
                    rebuildAllRow
                }
                .padding(.vertical, 4)
            } label: {
                disclosureLabel("settings.aiIndex.section", isExpanded: $isAIIndexExpanded)
            }
        }
    }

    /// 截断长度滑杆 + 数字读数。
    /// 决策 C2：范围 2000-32000，步进 1000。
    private var truncateLengthRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("settings.aiIndex.truncateLength")
                    .font(.callout)
                Spacer()
                Text("\(settings.aiReadmeTruncateLength)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: truncateLengthBinding,
                in: 2000...32000,
                step: 1000
            )
            Text("settings.aiIndex.truncateLength.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// HOM-197（2026-06-13 dong4j）：搜索结果过滤阈值滑杆。
    ///
    /// 形态完全复用 `truncateLengthRow` 骨架（标题 + 右上百分比 + Slider + 下方 hint），
    /// 让用户在同一组里横向看到的滑杆视觉语言一致。
    ///
    /// 配置：10% - 100%，步进 1%，默认 75%。生效路径见 `AppSettings
    /// .aiSemanticSearchScoreThreshold` 文档与 `HomeViewModel.applyView()` 的语义分支。
    private var scoreThresholdRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("settings.aiIndex.scoreThreshold")
                    .font(.callout)
                Spacer()
                Text("\(Int((settings.aiSemanticSearchScoreThreshold * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: scoreThresholdBinding,
                in: 0.10...1.00,
                step: 0.01
            )
            Text("settings.aiIndex.scoreThreshold.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 三档预设 + custom：segmented picker；switch 时同步 body/notes 字段。
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("settings.aiIndex.preset")
                    .font(.callout)
                Spacer()
            }
            Picker("", selection: presetBinding) {
                ForEach(AIIndexPreset.allCases) { preset in
                    Text(LocalizedStringKey(preset.displayNameKey)).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 高级区（折叠）：body / notes 阈值滑杆（HOM-197 2026-06-13 由 Stepper 改为 Slider）。
    /// 预设 != custom 时禁用编辑，提示用户先切到自定义。
    @ViewBuilder
    private var advancedDisclosure: some View {
        let isCustom = settings.aiIndexPreset == .custom
        DisclosureGroup(isExpanded: $isAIIndexAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ratioRow(
                    titleKey: "settings.aiIndex.bodyThreshold",
                    value: bodyRatioBinding,
                    enabled: isCustom
                )
                ratioRow(
                    titleKey: "settings.aiIndex.notesThreshold",
                    value: notesRatioBinding,
                    enabled: isCustom
                )
                if !isCustom {
                    Text("settings.aiIndex.advanced.lockedHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            disclosureLabel("settings.aiIndex.advanced", isExpanded: $isAIIndexAdvancedExpanded)
        }
    }

    /// 阈值行：与 `truncateLengthRow` / `scoreThresholdRow` 同款骨架——
    /// 标题 + 右上百分比读数 + Slider（HOM-197 dong4j 反馈，2026-06-13）。
    ///
    /// 范围 1% - 90%、步进 1%：
    /// - **下限 1%**：0% 意味着"任何字符差异都重建"会把 embedding 配额烧爆，
    ///   1% 起作为安全护栏；
    /// - **上限 90%**：现有最宽松预设 relaxed 是 20/30%，留出充足 headroom 给极端
    ///   "几乎不重建"场景；100% 等价于"永不自动重建" 没有实用意义；
    /// - 默认沿用 `DiffThresholds.default`（body 10% / notes 20%，即 standard 预设）。
    ///
    /// 预设非 `.custom` 时滑杆 `.disabled(!enabled)`；用户拖动后 binding 会自动把
    /// 预设切到 `.custom`（在 `bodyRatioBinding` / `notesRatioBinding` 的 set 闭包内
    /// 完成，与原 Stepper 行为一致）。
    private func ratioRow(titleKey: String, value: Binding<Double>, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(titleKey))
                    .font(.callout)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.01...0.90, step: 0.01)
                .disabled(!enabled)
        }
    }

    /// 开始 / 暂停 / 进度行。
    ///
    /// **2026-06-13 dong4j 反馈"开始预拉闪烁"改造**：
    /// `.alreadyUpToDate(total)` 与 `.completed` 共用按钮分支（都回到"开始预拉"），
    /// 右侧进度文字位置换成 `alreadyUpToDateBadge`——palette 模式渲染的白勾 + 深森林绿圆
    /// + 同色系文字"已是最新（共 N 个仓库）"，参考登录页 `GithubAuthView` 的复制成功
    /// 徽章姿势（保持视觉语言一致，新用户一眼就懂）。
    @ViewBuilder
    private var builderControlsRow: some View {
        let builder = dependencies.semanticIndexBuilder
        HStack(spacing: 10) {
            switch builder.status {
            case .idle, .completed, .alreadyUpToDate, .failed:
                Button(String.l10n("settings.aiIndex.prefetch.start")) {
                    builder.start()
                }
            case .running:
                Button(String.l10n("settings.aiIndex.prefetch.pause")) {
                    builder.pause()
                }
            case .paused:
                Button(String.l10n("settings.aiIndex.prefetch.resume")) {
                    builder.resume()
                }
            }
            Spacer()
            builderProgressView
        }
    }

    /// 右侧进度信息视图。`.alreadyUpToDate` 渲染为绿色 ✓ palette 徽章 + 友好文案，
    /// 其它状态保持原"caption 灰色文本"行为。
    @ViewBuilder
    private var builderProgressView: some View {
        let builder = dependencies.semanticIndexBuilder
        switch builder.status {
        case .alreadyUpToDate(let total):
            alreadyUpToDateBadge(total: total)
        default:
            Text(builderProgressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "已是最新"绿色徽章。
    ///
    /// 视觉规范（与登录页 `GithubAuthView` 的"已复制 ✓"反馈保持一致）：
    /// - 图标 `checkmark.circle.fill` 用 `symbolRenderingMode(.palette)` 渲染两层色：
    ///   ⚠️ palette 模式下 `foregroundStyle` 第一参数是**前景层（✓）**、第二参数是
    ///   **背景层（圆）**，给反了在浅色面板上会看不见圆，需小心顺序。
    ///   颜色取深森林绿（0.12, 0.42, 0.18）+ 白勾，"成功徽章"的常见视觉语义。
    /// - 文字与圆同色系，形成"图标 + 文字"一体的成功反馈块。
    /// - `total == 0` 时（用户没 starred 任何 repo）也走这条分支，文案"已是最新
    ///   （共 0 个仓库）"逻辑自洽——预拉完空集合本来就是"无事可做" = 已是最新。
    private func alreadyUpToDateBadge(total: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color(red: 0.12, green: 0.42, blue: 0.18))
                .font(.callout)
            Text(String(format: String.l10n("settings.aiIndex.prefetch.alreadyUpToDateFmt"), total))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color(red: 0.12, green: 0.42, blue: 0.18))
        }
    }

    private var builderProgressText: String {
        let b = dependencies.semanticIndexBuilder
        switch b.status {
        case .idle:
            return ""
        case .running, .paused:
            return String(
                format: String.l10n("settings.aiIndex.prefetch.progressFmt"),
                b.processed, b.total, b.failures
            )
        case .completed(let p, let t):
            return String(format: String.l10n("settings.aiIndex.prefetch.completedFmt"), p, t)
        case .alreadyUpToDate(let total):
            // builderProgressView 会优先走 alreadyUpToDateBadge 分支，这里只是为了
            // switch 穷举性兜底，理论上不会被调用到。返回 i18n 文案保持安全。
            return String(format: String.l10n("settings.aiIndex.prefetch.alreadyUpToDateFmt"), total)
        case .failed(let msg):
            return String(format: String.l10n("settings.aiIndex.prefetch.failedFmt"), msg)
        }
    }

    /// "全量重建"按钮。点击只弹确认 dialog，实际执行在 body 的 `.confirmationDialog`。
    private var rebuildAllRow: some View {
        HStack {
            Button(role: .destructive) {
                pendingRebuildAllConfirm = true
            } label: {
                Label("settings.aiIndex.rebuildAll.button", systemImage: "exclamationmark.triangle.fill")
            }
            Spacer()
            Text("settings.aiIndex.rebuildAll.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - AI 索引 bindings

    private var truncateLengthBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.aiReadmeTruncateLength) },
            set: { newValue in
                self.settings.aiReadmeTruncateLength = Int(newValue.rounded())
            }
        )
    }

    /// HOM-197：阈值滑杆 binding。
    /// `set` 端 clamp 到 [0.10, 1.00]——SwiftUI Slider 在 `step` 截断 + 浮点抖动下
    /// 偶尔会写出超出 `in:` 范围 1e-9 的值，clamp 是防御性兜底。
    private var scoreThresholdBinding: Binding<Double> {
        Binding(
            get: { self.settings.aiSemanticSearchScoreThreshold },
            set: { newValue in
                self.settings.aiSemanticSearchScoreThreshold = max(0.10, min(1.00, newValue))
            }
        )
    }

    private var presetBinding: Binding<AIIndexPreset> {
        Binding(
            get: { self.settings.aiIndexPreset },
            set: { self.settings.applyAIIndexPreset($0) }
        )
    }

    private var bodyRatioBinding: Binding<Double> {
        Binding(
            get: { self.settings.aiIndexBodyDiffRatio },
            set: { newValue in
                let clamped = max(0, min(1, newValue))
                self.settings.aiIndexBodyDiffRatio = clamped
                // 用户在高级区改具体数字 → 自动切到 custom（避免显示"标准"但数字漂移）
                if self.settings.aiIndexPreset != .custom {
                    self.settings.aiIndexPreset = .custom
                }
            }
        )
    }

    private var notesRatioBinding: Binding<Double> {
        Binding(
            get: { self.settings.aiIndexNotesDiffRatio },
            set: { newValue in
                let clamped = max(0, min(1, newValue))
                self.settings.aiIndexNotesDiffRatio = clamped
                if self.settings.aiIndexPreset != .custom {
                    self.settings.aiIndexPreset = .custom
                }
            }
        )
    }

    private var autoPrefetchBinding: Binding<Bool> {
        Binding(
            get: { self.settings.aiIndexAutoPrefetchEnabled },
            set: { self.settings.aiIndexAutoPrefetchEnabled = $0 }
        )
    }

    // MARK: - AI 代码上下文（2026-06-13 §0.4 Y3）
    //
    // 「AI 代码上下文」分组，对应 §0 客户端接入任务清单 §0.4 触点 C。
    //
    // 设计要点（沿用 promptSection / autoTidySection / aiIndexSection 同款风格）：
    //   - DisclosureGroup 默认折叠（@SceneStorage 持久化）；
    //   - 总开关 Toggle 控制下面控件的 disabled 状态（用户关掉总开关后调下面没意义）；
    //   - Slider 走 Int↔Double 适配 binding（SwiftUI Slider 强制 BinaryFloatingPoint，不能直接绑 Int）；
    //   - Stepper 走自定义 Int binding（AISettingsTab 没用 @Bindable var settings = settings）；
    //   - **不提供「私有仓库」开关**：当前 OAuth scope 是 `read:user` + `public_repo`，
    //     API 永远不会返回 isPrivate=true 的 repo；增加一个永远走不到的开关只会污染设置页；
    //   - 「管理已生成的上下文 →」按钮**当前先 print 占位**（Y3 仅 UI 阶段，Y5 触点 E 落地存储 Tab 才接通）。
    //
    // 关键约束：
    //   - 本 section 完全是 UI 层；改字段值只写 AppSettings UserDefaults，不触发任何 AI / 网络 / 磁盘 I/O。
    //   - 用户改 Slider/Stepper 立即落盘（didSet）；下次生成 AI 摘要才生效（X4 接通 RepoAIInsightService）。
    //   - X4 / Y5 未完成期间，本 section 是「光配置不生效」状态——用户改完看不到效果，但配置是真持久化的。

    private var aiRepoContextSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isRepoContextExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    repoContextEnableRow
                    Divider()
                    repoContextTokenBudgetRow
                    repoContextTier1MaxLinesRow
                    Divider()
                    repoContextManageStorageRow
                }
                .padding(.vertical, 4)
            } label: {
                disclosureLabel("ai.context.settings.title", isExpanded: $isRepoContextExpanded)
            }
        }
    }

    /// 总开关 + 一段说明 caption。
    /// caption 解释「会做什么 + 首次生成耗时预期」，让用户开启前有合理预期。
    private var repoContextEnableRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("ai.context.settings.enabled", isOn: repoContextEnabledBinding)
            Text("ai.context.settings.description")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Token 预算 Slider 行。范围 4000-32000、步进 2000——8 档刻度，
    /// 既不会让用户感到"想精调但跳得太大"，也不会让"步进 100"显得选择困难。
    private var repoContextTokenBudgetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ai.context.settings.tokenBudget")
                    .font(.callout)
                Spacer()
                Text("\(settings.aiRepoContextTokenBudget) tokens")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: tokenBudgetBinding,
                in: 4000...32000,
                step: 2000
            )
            .disabled(!settings.aiRepoContextEnabled)
        }
    }

    /// Tier 1 关键文件保留行数 Stepper 行。范围 40-200、步进 20。
    /// 单 Stepper 占一行（与 aiIndexSection 的 ratioRow 同样的「标题 + 读数 + 控件」横向布局）。
    ///
    /// HOM-203：右侧读数原本写成 `Text("ai.context...Format \(value)")`，被 SwiftUI
    /// 编译成 LocalizedStringKey `"ai.context...Format %@"`，xcstrings 中该带 `%@`
    /// 的 entry 是空壳，运行时找不到翻译就回退成"显示 key 字面量"，于是用户看到
    /// `ai.context.settings.tier1MaxLinesValueFormat 100` 这种纯 key。改成显式
    /// `String.l10n + String(format:)`，与本视图其它行（如 line 1480 的统计 cell）
    /// 风格保持一致；翻译模板里把 `%lld` 当行数占位符使用。
    private var repoContextTier1MaxLinesRow: some View {
        HStack {
            Text("ai.context.settings.tier1MaxLines")
                .font(.callout)
            Spacer()
            Text(String(
                format: String.l10n("ai.context.settings.tier1MaxLinesValueFormat"),
                settings.aiRepoContextTier1MaxLines
            ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Stepper(
                "",
                value: repoContextTier1MaxLinesBinding,
                in: 40...200,
                step: 20
            )
            .labelsHidden()
            .disabled(!settings.aiRepoContextEnabled)
        }
    }

    // MARK: - AI 代码上下文产物管理面板（HOM-68 v3 / 2026-06-15；HOM-203 性能改造）
    //
    // 历史背景：原方案只在 AI 设置里放一个「管理已生成的上下文 →」跳转按钮，把完整
    // 的输出目录 / 项目列表 / 单项删除面板放在 存储 Tab。dong4j 拍板把"精细化操作"
    // 集中到对应功能 Tab、把"全局汇总 + 一键清除"集中到 存储 Tab，因此本面板从
    // 存储 Tab 搬过来；存储 Tab 那边只保留汇总数字 + 行内"清理"按钮。
    //
    // **HOM-203（2026-06-16）改造**：用户反馈 576 个 repo 时本面板的 ForEach 渲染
    // 让设置页明显卡顿；同时 per-repo "打开 / 删除" 已被存储 Tab 的"全部清除"覆盖。
    // 决议：移除 ForEach + 单项 "打开 / 删除" 按钮；汇总统计源切到 `summary` 缓存
    // （`.starcat-summary.json`），UI 一次磁盘读取拿到 4 个数字，不再 O(n) 解析
    // metadata.json。详见 `RepoContextStorage` 的 HOM-203 注释。
    //
    // 视觉对照 `IntegrationSettingsView.codeFlowSection`，保持两类产物（CodeFlow /
    // RepoContextPacker）的 UI 节奏一致：
    //   1. 输出目录路径行 + 「选择目录 / 在 Finder 显示 / 重置默认」3 个按钮；
    //   2. 4 列汇总统计（项目数 / 占用 / 累计生成 / 最后生成）；
    //   3. 错误状态 / 空状态 提示。

    /// AI 代码上下文产物管理面板。
    @ViewBuilder
    private var repoContextManageStorageRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label("ai.context.storage.outputDirectory", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text("ai.context.storage.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(aiContextStorage.outputDirectoryDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                Spacer()
                Button("ai.context.storage.choose") {
                    chooseAIContextOutputDirectory()
                }
                .fixedSize()
                Button {
                    revealAIContextOutputDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .help(Text("ai.context.storage.revealHelp"))
                .fixedSize()
                Button {
                    resetAIContextOutputDirectory()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(!aiContextStorage.hasCustomOutputDirectory)
                .help(Text("ai.context.storage.resetHelp"))
                .fixedSize()
            }

            HStack(spacing: 18) {
                aiContextStat(titleKey: "ai.context.storage.statRepos",
                              value: "\(aiContextStorage.projectCount)")
                aiContextStat(titleKey: "ai.context.storage.statBytes",
                              value: ByteCountFormatter.string(fromByteCount: aiContextStorage.totalBytes, countStyle: .file))
                aiContextStat(titleKey: "ai.context.storage.statGenerations",
                              value: String(format: String.l10n("ai.context.storage.statGenerationsFormat"),
                                            aiContextStorage.totalGenerationCount))
                if let date = aiContextStorage.latestGeneratedAt {
                    aiContextStat(titleKey: "ai.context.storage.statLast",
                                  value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
            }

            // storage 内部抛错（bookmark 失效 / 目录权限丢失等）反映到 lastErrorMessage,
            // 持续显示直到下次 reload 成功。actionError（按钮触发的失败）走顶部 alert,
            // 两者职责分明：actionError = 短暂弹窗，lastErrorMessage = 持续状态。
            if let message = aiContextStorage.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if aiContextStorage.projectCount == 0 {
                Text("ai.context.storage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!settings.aiRepoContextEnabled)
    }

    /// 4 列汇总统计中的单列（caption2 标题 + caption.weight(.medium) 数值）。
    /// 视觉与 `IntegrationSettingsView.stat(title:value:)` 对齐。
    private func aiContextStat(titleKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    // MARK: - AI 代码上下文 storage action 入口

    /// 选择新的产物输出目录（NSOpenPanel）。失败走 aiContextActionError alert。
    private func chooseAIContextOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("ai.context.storage.choosePanelTitle")
        panel.prompt = String.l10n("ai.context.storage.choosePanelPrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try aiContextStorage.setCustomOutputDirectory(url)
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func resetAIContextOutputDirectory() {
        do {
            try aiContextStorage.resetOutputDirectory()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func revealAIContextOutputDirectory() {
        do {
            try aiContextStorage.revealOutputRoot()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    // HOM-203：单项 reveal / delete 已经移除——repo 列表整体砍掉，"全部清除"
    // 在 设置 → 存储 Tab 已有入口，不再需要单项操作。`storage.revealProject`
    // 和 `storage.deleteProject` API 仍保留供未来使用 / 单测。

    /// Token 预算 Int↔Double 适配 binding。
    /// SwiftUI Slider 要求 `BinaryFloatingPoint` 值类型，但 `aiRepoContextTokenBudget` 是 Int
    /// （UserDefaults 直接 Int 持久化更直观，避免出现 `8000.0`）。这里在两端之间做转换：
    ///   - get：Int → Double（无损扩展）
    ///   - set：Double → Int（`rounded()` 保证步进对齐到整 2000）
    private var tokenBudgetBinding: Binding<Double> {
        Binding(
            get: { Double(self.settings.aiRepoContextTokenBudget) },
            set: { newValue in
                self.settings.aiRepoContextTokenBudget = Int(newValue.rounded())
            }
        )
    }

    /// 总开关 Bool binding。AISettingsTab 没用 `@Bindable var settings = settings`（与
    /// SettingsView.generalTab 不同），所以子项 Toggle 不能直接 `$settings.xxx`，必须走
    /// 自定义 binding（与 `autoPrefetchBinding` 同款）。
    private var repoContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.aiRepoContextEnabled },
            set: { self.settings.aiRepoContextEnabled = $0 }
        )
    }

    /// Tier 1 行数 Int binding。Stepper 原生支持 Int，理论上可直接绑字段，但 AISettingsTab
    /// 没用 `@Bindable var settings = settings`，照样要自定义 binding。
    private var repoContextTier1MaxLinesBinding: Binding<Int> {
        Binding(
            get: { self.settings.aiRepoContextTier1MaxLines },
            set: { self.settings.aiRepoContextTier1MaxLines = $0 }
        )
    }

    /// 当前任务的占位符提示文案（2026-06-14 v4 占位符全栈归一化方案 C：单段 camelCase）。
    ///
    /// 各任务占位符**互不共享**——每个任务有自己独立的占位符命名空间：
    /// - **summary**：5 个占位符（system 用 `{outputLanguage}`；user 用 `{outputLanguage}` /
    ///   `{metadata}` / `{readme}` / `{codeContext}` / `{externalContext}`）；详见
    ///   `AIDefaultPrompts.summary` 的注释。
    /// - **tags**：6 个占位符（system 用 `{outputLanguage}`；user 用 `{metadata}` /
    ///   `{readme}` / `{codeContext}` / `{repoTags}` / `{libraryTags}`）；详见
    ///   `AIDefaultPrompts.tags` 的注释。
    /// - **chat**：6 个占位符（system 用 `{outputLanguage}` / `{metadata}` / `{readme}` /
    ///   `{codeContext}` / `{summary}` / `{externalContext}`；userPromptTemplate 留空，
    ///   用户消息直接走 messages 数组）；详见 `AIDefaultPrompts.chat` 的注释。
    /// - **embedding**：8 个占位符（`{fullName}` / `{description}` / `{language}` / `{topics}` /
    ///   `{license}` / `{homepage}` / `{body}` / `{notes}`）；详见 `AIDefaultPrompts.embedding`
    ///   的注释；embedding API 不接受 system prompt，所以 system 一栏空且不会被使用。
    /// - **translation**：`{targetLanguage}` + `{readmeHTML}`；详见 `AIDefaultPrompts.translation`
    ///   的注释（2026-06-14 v2 占位符由 `{context}` 重命名为 `{readmeHTML}`）。
    ///
    /// **删占位符 = 不注入对应数据**：用户在 prompt 里删掉某个占位符就不会渲染对应内容；
    /// 改坏了点 Restore Default 还原。
    private var promptPlaceholderHint: String {
        switch promptTask {
        case .summary:
            return String.l10n("settings.ai.prompt.placeholders.summary")
        case .tags:
            return String.l10n("settings.ai.prompt.placeholders.tags")
        case .translation:
            return String.l10n("settings.ai.prompt.placeholders.translation")
        case .embedding:
            return String.l10n("settings.ai.prompt.placeholders.embedding")
        case .chat:
            return String.l10n("settings.ai.prompt.placeholders.chat")
        }
    }

    private var privacySection: some View {
        Section {
            Label {
                Text("settings.ai.privacy.notice")
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

    // `deleteSelectedProfile()` 已被 `deleteProfile(id:)` + `confirmationDialog`
    // 二次确认链路取代（HOM-AIPROVIDERS-DELETE-CONFIRM-2026-06-12）。原函数
    // 隐式依赖 `selectedProfileID`，confirm dialog 期间用户可能切换 selection
    // 导致语义偏差，新函数收紧到显式 ID 删除。

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
                // HOM-AIPROVIDERS-HIDE-PROVIDER-2026-06-12：包 withAnimation 让
                // Provider 行随草稿晋升收起，与点 + 时的滑入动画对称。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    draftProfile = nil
                    draftAPIKey = ""
                }
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
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
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
            case .chat:
                config.prompt = AIDefaultPrompts.chat
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
        case .chat:        return settings.aiChatTask
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
        case .chat:
            settings.aiChatTask = config
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
