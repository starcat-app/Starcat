//
//  TranslationSettingsView.swift
//  Starcat
//
//  翻译设置只管理引擎及其专属配置，目标语言继续来自现有翻译入口。
//  服务商与模型目录在模型页统一管理；分段 / 全文提示词在同一弹窗中切换并即时保存。
//  Google 凭据先经实际所选通道验证，再保存或删除；失败与迟到结果均不覆盖既有配置。
//

import SwiftUI

/// 原生翻译设置表单；沿用语言包目录、翻译任务存储和运行时客户端。
@MainActor
struct TranslationSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var availableEngines: [ReadmeTranslationEngine] = []
    @State private var systemLanguageCatalog = SystemTranslationLanguageCatalog()
    @State private var isSystemLanguageManagerPresented = false
    @State private var googleAPIKey = ""
    @State private var isTestingGoogleKey = false
    @State private var googleKeyError: String?
    @State private var isGoogleKeyApplied = false
    /// 输入或引擎变更时取消本次验证，身份同时阻挡不响应取消的迟到请求提交旧草稿。
    @State private var googleTestTask: Task<Void, Never>?
    @State private var googleTestID: UUID?
    /// 模式只决定当前编辑的提示词，不复制或切换翻译任务模型。
    @State private var promptMode: ReadmeTranslationMode = .segmented
    @State private var isPromptEditorPresented = false

    var body: some View {
        Form {
            introductionSection
            engineSection
            if settings.readmeTranslationEngine == .system {
                systemTranslationSection
            }
            if settings.readmeTranslationEngine == .google {
                googleSection
            }
            if settings.readmeTranslationEngine == .ai {
                aiTranslationSection
            }
        }
        .formStyle(.grouped)
        .task(id: settings.effectiveReadmeTranslationLanguage) {
            await refreshEngines()
        }
        .task { loadGoogleAPIKey() }
        .sheet(isPresented: $isSystemLanguageManagerPresented) {
            SystemTranslationLanguageManagerSheet(
                targetLanguage: settings.effectiveReadmeTranslationLanguage,
                catalog: systemLanguageCatalog,
                openSystemSettings: openSystemLanguageSettings
            )
            .appLocaleEnvironment()
        }
        .sheet(isPresented: $isPromptEditorPresented) {
            TranslationPromptSheet(
                mode: $promptMode,
                systemPrompt: { promptSystemBinding(for: $0) },
                userPrompt: { promptUserBinding(for: $0) },
                onRestoreDefault: restoreDefaultPrompt
            )
            .appLocaleEnvironment()
        }
        .onChange(of: settings.readmeTranslationEngine) { _, engine in
            if engine != .google { cancelGoogleKeyTest() }
        }
        .onChange(of: settings.effectiveReadmeTranslationLanguage) { _, _ in
            cancelGoogleKeyTest()
        }
        .onDisappear { cancelGoogleKeyTest() }
    }

    /// 与模型页共用说明卡片的视觉结构，表面交给 grouped Form，避免卡片套卡片。
    private var introductionSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "character.bubble")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.navigation.item.translation")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.navigation.item.translation"))
                    Text("settings.translation.introduction.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.translation.introduction.description"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - 引擎与系统翻译

    private var engineSection: some View {
        Section {
            if availableEngines.isEmpty {
                Text("settings.translation.engine.empty")
                    .foregroundStyle(.secondary)
            } else {
                centeredRow {
                    Picker("settings.translation.engine.default", selection: Binding(
                        get: { settings.readmeTranslationEngine },
                        set: { settings.readmeTranslationEngine = $0 }
                    )) {
                        ForEach(availableEngines) { engine in
                            Text(LocalizedStringKey(engine.displayNameKey)).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.translation.engine.default")
                            .lineLimit(1)
                        Text("settings.translation.layout.engine.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(Text("settings.translation.layout.engine.help"))
                    }
                }
            }
        } header: {
            SettingsSectionHeader("settings.translation.section.engine", systemImage: "character.bubble")
        }
    }

    /// 只展示实际语言组合的就绪摘要；完整下载与管理继续交给原语言包窗口。
    private var systemTranslationSection: some View {
        let target = settings.effectiveReadmeTranslationLanguage
        return Section {
            centeredRow {
                if !systemLanguageCatalog.isLoaded(for: target) || systemLanguageCatalog.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if systemLanguageCatalog.availablePairCount == 0 {
                    Label("settings.translation.layout.system.unavailable", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else if systemLanguageCatalog.readyCount == systemLanguageCatalog.availablePairCount {
                    Label("settings.translation.layout.system.ready", systemImage: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    Label("settings.translation.layout.system.available", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.translation.layout.system.packages")
                        .lineLimit(1)
                    Text(verbatim: systemLanguageReadinessText(for: target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            centeredRow {
                Button("settings.translation.layout.system.view") {
                    isSystemLanguageManagerPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } label: {
                Text("settings.translation.layout.system.manage")
                    .lineLimit(1)
            }
        } header: {
            SettingsSectionHeader("settings.translation.section.system", systemImage: "laptopcomputer")
        }
        .task(id: target.rawValue) {
            await systemLanguageCatalog.refresh(target: target)
        }
    }

    /// 数字是当前目标语言下的可用组合，不将 Apple 提供的组合状态误称为语言包文件数量。
    private func systemLanguageReadinessText(for target: ReadmeTranslationLanguage) -> String {
        guard systemLanguageCatalog.isLoaded(for: target) else {
            return String.l10n("settings.translation.system.readiness.loading")
        }
        return String(
            format: String.l10n("settings.translation.layout.system.readiness"),
            systemLanguageCatalog.readyCount,
            systemLanguageCatalog.availablePairCount
        )
    }

    /// 系统设置入口保留在现有语言包管理窗口；Apple 没有公开直达翻译语言子窗口的稳定 API。
    private func openSystemLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        openURL(url)
    }

    // MARK: - Google 翻译

    private var googleSection: some View {
        Section {
            SettingsAPIKeyField(
                title: "settings.translation.google.apiKey.field", text: googleAPIKeyBinding
            )

            HStack(spacing: 8) {
                if isTestingGoogleKey {
                    ProgressView().controlSize(.small)
                    Text("settings.services.summary.checking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let googleKeyError {
                    Label {
                        Text(verbatim: googleKeyError)
                            .lineLimit(2)
                            .help(googleKeyError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                } else if isGoogleKeyApplied {
                    Label("settings.translation.layout.google.applied", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                Button("settings.connection.getAPIKey") {
                    openGoogleConsole()
                }
                .buttonStyle(.link)
                .font(.caption)
                .fixedSize()
                Button(action: startGoogleKeyTest) {
                    Text("settings.translation.layout.google.testApply")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isTestingGoogleKey)
            }
        } header: {
            SettingsSectionHeader("settings.translation.section.google", systemImage: "globe")
        }
    }

    private func openGoogleConsole() {
        guard let url = URL(string: "https://console.cloud.google.com/apis/credentials") else { return }
        openURL(url)
    }

    // MARK: - AI 翻译

    private var aiTranslationSection: some View {
        Section {
            centeredRow {
                AITaskModelPicker(
                    title: "settings.ai.models.model.title",
                    profiles: verifiedProfiles,
                    selection: translationModelBinding,
                    providerDisplayName: translationProviderName,
                    availableModels: enabledModels(in:)
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.model.title")
                        .lineLimit(1)
                    Text("settings.translation.layout.ai.model.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.translation.layout.ai.model.help"))
                }
            }
            centeredRow {
                Button("settings.ai.models.prompt.edit") {
                    isPromptEditorPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.translation.ai.prompt")
                        .lineLimit(1)
                    Text("settings.translation.layout.prompt.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.translation.layout.prompt.help"))
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button("settings.translation.layout.ai.manageProviders") {
                    NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.models")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .lineLimit(1)
                .help(Text("settings.translation.layout.ai.manageProviders"))
            }
        } header: {
            SettingsSectionHeader("settings.translation.ai.section", systemImage: "sparkles")
        }
    }

    /// 两行说明作为同一个标签块居中，避免 Form 首行基线把右侧控件顶到上方。
    private func centeredRow<Content: View, RowLabel: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> RowLabel
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            label().frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - AI 翻译数据源与原任务绑定

    private var verifiedProfiles: [AIProviderProfile] {
        settings.aiProviderProfiles.filter(\.isVerifiedConfiguration)
    }

    /// 翻译仍只接受已启用的 Chat / Unknown 模型，与模型页菜单使用相同的能力口径。
    private func enabledModels(in profile: AIProviderProfile) -> [AIModelDescriptor] {
        profile.models.filter {
            $0.isEnabled && ($0.capability == .chat || $0.capability == .unknown)
        }
    }

    private var translationProviderName: String {
        let providerID = settings.resolvedAITask(settings.aiTranslationTask).providerID
        return settings.aiProviderProfiles.first { $0.id == providerID }?.displayName ?? providerID
    }

    /// 菜单身份包含服务商，避免多个兼容服务返回同名模型时同时选中。
    private var translationModelBinding: Binding<AITaskModelPicker.Selection> {
        Binding(
            get: {
                let config = settings.resolvedAITask(settings.aiTranslationTask)
                return AITaskModelPicker.Selection(
                    providerID: config.providerID,
                    modelName: config.useCustomModel ? config.customModelName : config.modelID,
                    isCustom: config.useCustomModel
                )
            },
            set: { selection in
                guard !selection.isCustom,
                      let profile = verifiedProfiles.first(where: { $0.id == selection.providerID }),
                      enabledModels(in: profile).contains(where: { $0.name == selection.modelName }) else { return }
                var config = settings.aiTranslationTask
                settings.selectLocalAIModel(named: selection.modelName, providerID: selection.providerID)
                config.providerID = selection.providerID
                config.modelID = selection.modelName
                config.useCustomModel = false
                settings.aiTranslationTask = config
            }
        )
    }

    /// 分段模式读写 `aiTranslationTask.prompt`；全文模式读写独立的 `aiFullTranslationPrompt`。
    private func promptSystemBinding(for mode: ReadmeTranslationMode) -> Binding<String> {
        if mode == .full {
            return Binding(
                get: { settings.aiFullTranslationPrompt.systemPrompt },
                set: { value in
                    var prompt = settings.aiFullTranslationPrompt
                    prompt.systemPrompt = value
                    settings.aiFullTranslationPrompt = prompt
                }
            )
        }
        return Binding(
            get: { settings.aiTranslationTask.prompt.systemPrompt },
            set: { value in
                var config = settings.aiTranslationTask
                config.prompt.systemPrompt = value
                settings.aiTranslationTask = config
            }
        )
    }

    private func promptUserBinding(for mode: ReadmeTranslationMode) -> Binding<String> {
        if mode == .full {
            return Binding(
                get: { settings.aiFullTranslationPrompt.userPromptTemplate },
                set: { value in
                    var prompt = settings.aiFullTranslationPrompt
                    prompt.userPromptTemplate = value
                    settings.aiFullTranslationPrompt = prompt
                }
            )
        }
        return Binding(
            get: { settings.aiTranslationTask.prompt.userPromptTemplate },
            set: { value in
                var config = settings.aiTranslationTask
                config.prompt.userPromptTemplate = value
                settings.aiTranslationTask = config
            }
        )
    }

    /// 与 AI 服务页同语义：分段重置任务内 Prompt，全文重置独立存储的全文 Prompt。
    private func restoreDefaultPrompt(_ mode: ReadmeTranslationMode) {
        if mode == .full {
            settings.aiFullTranslationPrompt = AIDefaultPrompts.fullTranslation
            return
        }
        var config = settings.aiTranslationTask
        config.prompt = AIDefaultPrompts.translation
        settings.aiTranslationTask = config
    }

    // MARK: - 引擎可用性

    @MainActor
    private func refreshEngines() async {
        let available = await ReadmeTranslationEngineAvailability.availableEngines(
            targetLanguage: settings.effectiveReadmeTranslationLanguage,
            settings: settings,
            keychain: KeychainManager.shared
        )
        availableEngines = available
        let resolved = ReadmeTranslationEngineAvailability.resolvedDefault(
            current: settings.readmeTranslationEngine,
            available: available
        )
        if resolved != settings.readmeTranslationEngine, !available.isEmpty {
            settings.readmeTranslationEngine = resolved
        }
    }

    // MARK: - Google 验证与凭据提交

    /// 只有用户编辑输入时失效验证，成功后标准化空格不会误清除刚显示的成功状态。
    private var googleAPIKeyBinding: Binding<String> {
        Binding(
            get: { googleAPIKey },
            set: { value in
                cancelGoogleKeyTest()
                googleAPIKey = value
                googleKeyError = nil
            }
        )
    }

    /// 点击时捕获候选输入，空 Key 也复用现有客户端的公开接口进行真实测试。
    private func startGoogleKeyTest() {
        guard !isTestingGoogleKey else { return }
        let candidate = googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = settings.effectiveReadmeTranslationLanguage
        let attemptID = UUID()
        googleTestID = attemptID
        googleKeyError = nil
        isGoogleKeyApplied = false
        isTestingGoogleKey = true
        googleTestTask = Task {
            await testAndApplyGoogleKey(candidate, target: target, attemptID: attemptID)
        }
    }

    /// 网络通过后才同步提交凭据；清空旧 Key 同样先验证公开通道，失败保留原配置。
    /// 输入、目标或引擎改变后旧任务不得提交，defer 也不能清掉新任务的状态。
    private func testAndApplyGoogleKey(
        _ candidate: String,
        target: ReadmeTranslationLanguage,
        attemptID: UUID
    ) async {
        defer {
            if googleTestID == attemptID {
                isTestingGoogleKey = false
                googleTestTask = nil
                googleTestID = nil
            }
        }
        do {
            _ = try await GoogleTranslationClient(apiKey: candidate).translate(
                texts: ["hello"],
                targetLanguage: target
            )
            try Task.checkCancellation()
            guard googleTestID == attemptID,
                  googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) == candidate,
                  settings.effectiveReadmeTranslationLanguage == target,
                  settings.readmeTranslationEngine == .google else { return }

            if candidate.isEmpty {
                try KeychainManager.shared.deleteServiceAPIKey(forService: GoogleTranslationClient.keychainServiceID)
            } else {
                try KeychainManager.shared.storeServiceAPIKey(candidate, forService: GoogleTranslationClient.keychainServiceID)
            }
            googleAPIKey = candidate
            isGoogleKeyApplied = true
        } catch {
            guard googleTestID == attemptID, !Task.isCancelled else { return }
            googleKeyError = error.localizedDescription
        }
    }

    /// 失效身份优先于等待网络取消，防止旧响应覆盖用户下一次编辑或离开页面后的配置。
    private func cancelGoogleKeyTest() {
        googleTestTask?.cancel()
        googleTestTask = nil
        googleTestID = nil
        isTestingGoogleKey = false
        isGoogleKeyApplied = false
    }

    private func loadGoogleAPIKey() {
        googleAPIKey = (try? KeychainManager.shared.loadServiceAPIKey(
            forService: GoogleTranslationClient.keychainServiceID
        )) ?? ""
    }
}

#Preview {
    TranslationSettingsTab()
        .environment(AppSettings.shared)
}
