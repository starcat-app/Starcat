//
//  AISettingsView.swift
//  Starcat
//
//  AI 服务配置面板。
//
//  设计思路：
//  - 使用 macOS 原生 Form + .formStyle(.grouped) 保持系统设置的一致感。
//  - 提供 Provider 切换（目前首选 OpenAI）。
//  - 支持自定义 Base URL 以兼容各类 OpenAI API 格式的服务商（如 DeepSeek, OpenRouter 等）。
//  - API Key 字段使用 SecureField 保护隐私。
//

import SwiftUI

/// AI 服务提供商枚举
enum AIProvider: String, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case gemini = "Gemini"
    case deepseek = "DeepSeek"
    case ollama = "Ollama"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .openai: return "sparkles"
        case .gemini: return "shimmer"
        case .deepseek: return "brain"
        case .ollama: return "terminal"
        }
    }
}

/// AI 设置 Tab 页面
struct AISettingsTab: View {
    
    // 目前业务逻辑先放一放，使用临时的 @State 模拟绑定
    @State private var selectedProvider: AIProvider = .openai
    @State private var openaiBaseURL: String = "https://api.openai.com/v1"
    @State private var openaiAPIKey: String = ""
    @State private var selectedModel: String = "gpt-4o"
    @State private var customModelName: String = ""
    
    var body: some View {
        Form {
            Section {
                Picker(selection: $selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Label(provider.rawValue, systemImage: provider.icon)
                            .tag(provider)
                    }
                } label: {
                    Text("settings.ai.provider")
                }
                .pickerStyle(.menu)
            } header: {
                Text("settings.ai.serviceConfig")
            } footer: {
                Text("settings.ai.provider.description")
            }
            
            if selectedProvider == .openai {
                openaiConfigSection
            } else {
                comingSoonSection
            }
            
            Section {
                LabeledContent("settings.ai.status") {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(.gray)
                            .font(.system(size: 8))
                        Text("settings.ai.status.notConfigured")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button("settings.ai.testConnection") {
                    // TODO: 实现连接测试逻辑
                }
                .disabled(openaiAPIKey.isEmpty)
            } header: {
                Text("settings.ai.connection")
            }
        }
        .formStyle(.grouped)
    }
    
    /// OpenAI 专用的配置段
    private var openaiConfigSection: some View {
        Section {
            TextField("settings.ai.openai.baseUrl", text: $openaiBaseURL)
                .textFieldStyle(.roundedBorder)
            
            SecureField("settings.ai.openai.apiKey", text: $openaiAPIKey)
                .textFieldStyle(.roundedBorder)
            
            Picker("settings.ai.openai.model", selection: $selectedModel) {
                Text("gpt-4o").tag("gpt-4o")
                Text("gpt-4o-mini").tag("gpt-4o-mini")
                Text("gpt-3.5-turbo").tag("gpt-3.5-turbo")
                Divider()
                Text("settings.ai.customModel").tag("custom")
            }
            
            if selectedModel == "custom" {
                TextField("settings.ai.openai.customModelName", text: $customModelName)
                    .textFieldStyle(.roundedBorder)
            }
        } header: {
            Text("settings.ai.openai.config")
        } footer: {
            Text("settings.ai.openai.baseUrl.help")
        }
    }
    
    /// 占位段：尚未实现的服务商
    private var comingSoonSection: some View {
        Section {
            ContentUnavailableView {
                Label {
                    Text("\(selectedProvider.rawValue) Coming Soon")
                } icon: {
                    Image(systemName: selectedProvider.icon)
                }
            } description: {
                Text("settings.ai.provider.notImplemented")
            }
        }
    }
}

#Preview {
    AISettingsTab()
        .frame(width: 500, height: 400)
}
