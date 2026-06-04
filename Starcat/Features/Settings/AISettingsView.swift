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
            Picker("服务商配置", selection: selectedProfileBinding) {
                ForEach(settings.aiProviderProfiles) { profile in
                    Text(profile.displayName).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button {
                    addProfile()
                } label: {
                    Label("新增服务商", systemImage: "plus")
                }

                Button(role: .destructive) {
                    deleteSelectedProfile()
                } label: {
                    Label("删除当前", systemImage: "trash")
                }
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

                HStack {
                    Button {
                        saveAPIKey(profileID: profile.id)
                    } label: {
                        Label("保存 Key", systemImage: "key.fill")
                    }

                    Button {
                        Task { await testAndFetchModels(profile) }
                    } label: {
                        if isTestingProfileID == profile.id {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("测试并获取模型")
                            }
                        } else {
                            Label("测试并获取模型", systemImage: "network")
                        }
                    }
                    .disabled(isTestingProfileID != nil || (!profile.provider.allowsEmptyAPIKey && apiKeys[profile.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                    Spacer()
                    Text(profile.lastTestStatus.displayText)
                        .font(.caption)
                        .foregroundStyle(statusTint(profile.lastTestStatus))
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
        Section {
            if let profile = selectedProfile {
                if profile.models.isEmpty {
                    Text("暂无模型。点击“测试并获取模型”，或在模型设置中使用自定义模型名。")
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
        } header: {
            Text("已发现模型")
        } footer: {
            Text("模型列表在组件内滚动，避免服务商返回大量模型时撑高整个设置页。")
        }
    }

    // MARK: - Tasks

    private var taskModelsSection: some View {
        Section {
            taskModelRow(.summary)
            taskModelRow(.tags)
            taskModelRow(.embedding)
        } header: {
            Text("模型设置")
        } footer: {
            Text("下拉框只展示已启用模型；如果服务商暂时无法列出模型，可以打开自定义模型名手动输入。")
        }
    }

    private func taskModelRow(_ task: AIModelTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.displayName)
                .font(.subheadline.weight(.semibold))

            HStack {
                Picker("Provider", selection: taskProviderBinding(task)) {
                    ForEach(settings.aiProviderProfiles.filter(\.isEnabled)) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Picker("模型", selection: taskModelBinding(task)) {
                    ForEach(groupedEnabledModels(for: task), id: \.profile.id) { group in
                        Section(group.profile.displayName) {
                            ForEach(group.models) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)

                Toggle("自定义", isOn: taskCustomEnabledBinding(task))
                    .toggleStyle(.checkbox)
            }

            if taskConfig(task).useCustomModel {
                TextField("自定义模型名", text: taskCustomModelBinding(task))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Parameters

    private var parametersSection: some View {
        Section {
            Picker("任务", selection: $parameterTask) {
                ForEach(AIModelTask.allCases) { task in
                    Text(task.displayName).tag(task)
                }
            }
            .pickerStyle(.segmented)

            let isEmbedding = parameterTask == .embedding
            parameterSlider("Temperature", value: parameterDoubleBinding(parameterTask, \.temperature), range: 0...2, disabled: isEmbedding)
            parameterSlider("Top P", value: parameterDoubleBinding(parameterTask, \.topP), range: 0...1, disabled: isEmbedding)
            Stepper("Top K：\(taskConfig(parameterTask).parameters.topK)", value: parameterIntBinding(parameterTask, \.topK), in: 0...200)
                .disabled(isEmbedding)
            Stepper("最大 Token：\(taskConfig(parameterTask).parameters.maxCompletionTokens)", value: parameterIntBinding(parameterTask, \.maxCompletionTokens), in: 0...32_000, step: 256)
                .disabled(isEmbedding)
            Stepper("超时时间：\(Int(taskConfig(parameterTask).parameters.timeoutSeconds)) 秒", value: parameterDoubleBinding(parameterTask, \.timeoutSeconds), in: 30...900, step: 30)
            Toggle("优先使用流式响应", isOn: parameterBoolBinding(parameterTask, \.streamEnabled))
                .disabled(parameterTask != .summary)
        } header: {
            Text("模型参数")
        } footer: {
            Text("Top K 不是 OpenAI Chat Completions 标准字段，当前仅保存配置；后续针对 LM Studio / Ollama 原生扩展时再发送。")
        }
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

    // MARK: - Prompt

    private var promptSection: some View {
        Section {
            Picker("任务", selection: $promptTask) {
                ForEach([AIModelTask.summary, .tags]) { task in
                    Text(task.displayName).tag(task)
                }
            }
            .pickerStyle(.segmented)

            Text("System Prompt")
                .font(.caption.weight(.semibold))
            TextEditor(text: promptSystemBinding(promptTask))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 86)

            Text("User Prompt Template")
                .font(.caption.weight(.semibold))
            TextEditor(text: promptUserBinding(promptTask))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 150)

            Button {
                restoreDefaultPrompt(promptTask)
            } label: {
                Label("恢复默认 Prompt", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Prompt")
        } footer: {
            Text("User Prompt 中的 {context} 会在运行时替换为仓库元数据和 README 摘要。")
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
        case .summary:   return settings.aiSummaryTask
        case .tags:      return settings.aiTagsTask
        case .embedding: return settings.aiEmbeddingTask
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
        }
    }

    private func groupedEnabledModels(for task: AIModelTask) -> [(profile: AIProviderProfile, models: [AIModelDescriptor])] {
        settings.aiProviderProfiles.compactMap { profile in
            let models = enabledModels(providerID: profile.id, capability: task.requiredCapability)
            return models.isEmpty ? nil : (profile, models)
        }
    }

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
