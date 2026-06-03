//
//  AISettingsView.swift
//  Starcat
//
//  AI 服务配置面板。
//
//  模块级说明：
//  - 本页面实现 BYOK（Bring Your Own Key）：用户自己填写 API Key、Base URL 和模型。
//  - API Key 写入 `KeychainManager` 管理的本地加密文件，其他偏好写入 `AppSettings`。
//  - 第一阶段统一走 OpenAI-compatible API，底层 adapter 使用 MacPaw/OpenAI。
//
//  关键约束：
//  - 不把 API Key 存入 UserDefaults，也不打印到日志。
//  - 不默认使用 Starcat 自建服务端；所有请求直连用户配置的 provider。
//  - `测试连接` 只验证 embedding 链路，因为语义搜索第一版强依赖 embeddings。
//

import SwiftUI

/// AI 设置 Tab 页面。
struct AISettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var apiKey: String = ""
    @State private var isLoadingKey: Bool = true
    @State private var isSavingKey: Bool = false
    @State private var isTesting: Bool = false
    @State private var status: ConnectionStatus = .idle
    @State private var keyError: String?

    /// 设置页连接状态。
    private enum ConnectionStatus: Equatable {
        case idle
        case saved
        case testing
        case success
        case failed(String)

        var text: String {
            switch self {
            case .idle:        return "未测试"
            case .saved:       return "已保存，尚未测试"
            case .testing:     return "正在测试..."
            case .success:     return "连接正常"
            case .failed(let message): return message
            }
        }

        var symbol: String {
            switch self {
            case .idle, .saved: return "circle.fill"
            case .testing:      return "clock"
            case .success:      return "checkmark.circle.fill"
            case .failed:       return "xmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .idle, .saved: return .secondary
            case .testing:      return .blue
            case .success:      return .green
            case .failed:       return .red
            }
        }
    }

    var body: some View {
        @Bindable var settings = settings

        return Form {
            providerSection(
                aiProvider: $settings.aiProvider,
                aiBaseURL: $settings.aiBaseURL
            )
            modelSection(
                aiChatModel: $settings.aiChatModel,
                aiEmbeddingModel: $settings.aiEmbeddingModel
            )
            keySection
            connectionSection
            privacySection
        }
        .formStyle(.grouped)
        .task {
            loadAPIKey()
        }
        .onChange(of: settings.aiProvider) { _, newProvider in
            applyDefaults(for: newProvider)
        }
    }

    /// Provider 与 Base URL。
    private func providerSection(
        aiProvider: Binding<AIServiceProvider>,
        aiBaseURL: Binding<String>
    ) -> some View {
        Section {
            Picker("AI Provider", selection: aiProvider) {
                ForEach(AIServiceProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)

            TextField("Base URL", text: aiBaseURL)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            Text("例如：https://api.openai.com/v1、https://api.deepseek.com/v1、http://localhost:11434/v1")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI 服务")
        } footer: {
            Text("Starcat 第一阶段使用 OpenAI-compatible 协议；DeepSeek、OpenRouter、Ollama、LM Studio 都通过 Base URL 适配。")
        }
    }

    /// 模型配置。
    private func modelSection(
        aiChatModel: Binding<String>,
        aiEmbeddingModel: Binding<String>
    ) -> some View {
        Section {
            TextField("摘要 / 标签模型", text: aiChatModel)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            TextField("Embedding 模型", text: aiEmbeddingModel)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
        } header: {
            Text("模型")
        } footer: {
            Text("聊天模型用于单仓摘要和标签推荐；Embedding 模型用于本地 SQLite 语义搜索索引。")
        }
    }

    /// API Key 区域。
    private var keySection: some View {
        Section {
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isLoadingKey || isSavingKey)

            HStack {
                Button {
                    saveAPIKey()
                } label: {
                    Label("保存 Key", systemImage: "key.fill")
                }
                .disabled(isLoadingKey || isSavingKey)

                Button(role: .destructive) {
                    deleteAPIKey()
                } label: {
                    Label("删除 Key", systemImage: "trash")
                }
                .disabled(isLoadingKey || isSavingKey || apiKey.isEmpty)

                if isSavingKey {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("BYOK API Key")
        } footer: {
            Text("API Key 仅保存在本机加密文件中；不会写入 UserDefaults，也不会随日志输出。")
        }
    }

    /// 连接测试。
    private var connectionSection: some View {
        Section {
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.tint)
                    Text(status.text)
                        .foregroundStyle(status.tint)
                }
            }

            Button {
                Task { await testConnection() }
            } label: {
                if isTesting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("测试连接")
                    }
                } else {
                    Label("测试连接", systemImage: "network")
                }
            }
            .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("连接")
        } footer: {
            Text("测试会向配置的 Provider 发起一次极短 embedding 请求，用于验证 Key、Base URL 和 Embedding 模型。")
        }
    }

    /// 隐私提示。
    private var privacySection: some View {
        Section {
            Label {
                Text("Starcat 不经过自建服务器转发 AI 请求。摘要、标签推荐和语义搜索会把必要的仓库元数据 / README 摘要发送给你配置的 Provider。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
            }
        }
    }

    private func loadAPIKey() {
        isLoadingKey = false
        do {
            apiKey = try KeychainManager.shared.loadAIKey() ?? ""
            status = apiKey.isEmpty ? .idle : .saved
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func saveAPIKey() {
        isSavingKey = true
        keyError = nil
        defer { isSavingKey = false }

        do {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try KeychainManager.shared.deleteAIKey()
                status = .idle
            } else {
                try KeychainManager.shared.storeAIKey(trimmed)
                apiKey = trimmed
                status = .saved
            }
        } catch {
            keyError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    private func deleteAPIKey() {
        isSavingKey = true
        keyError = nil
        defer { isSavingKey = false }

        do {
            try KeychainManager.shared.deleteAIKey()
            apiKey = ""
            status = .idle
        } catch {
            keyError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func testConnection() async {
        isTesting = true
        status = .testing
        defer { isTesting = false }

        do {
            let client = try OpenAIClient(configuration: AIClientConfiguration(
                apiKey: apiKey,
                baseURL: settings.aiBaseURL,
                chatModel: settings.aiChatModel,
                embeddingModel: settings.aiEmbeddingModel
            ))
            try await client.testConnection()
            status = .success
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Provider 切换时带出默认值。
    ///
    /// 这是设置页少数“主动改其他字段”的逻辑：Provider 一旦切换，旧模型名往往不可用。
    /// 自动填默认值能让用户更快完成配置；仍允许用户随后手动覆盖。
    private func applyDefaults(for provider: AIServiceProvider) {
        settings.aiBaseURL = provider.defaultBaseURL
        settings.aiChatModel = provider.defaultChatModel
        settings.aiEmbeddingModel = provider.defaultEmbeddingModel
        status = apiKey.isEmpty ? .idle : .saved
    }
}

#Preview {
    AISettingsTab()
        .environment(AppSettings(defaults: .standard))
        .frame(width: 520, height: 460)
}
