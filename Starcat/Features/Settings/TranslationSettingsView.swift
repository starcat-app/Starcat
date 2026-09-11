//
//  TranslationSettingsView.swift
//  Starcat
//
//  「翻译服务」设置页：默认引擎 + Apple / Google 翻译说明与凭据。
//  AI 的 Provider / Prompt 仍在 AI 设置，这里只选「用谁译」。
//

import SwiftUI

struct TranslationSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var availableEngines: [ReadmeTranslationEngine] = []
    @State private var googleAPIKey = ""
    @State private var hasStoredGoogleAPIKey = false
    @State private var isGoogleAPIKeyVisible = false

    var body: some View {
        Form {
            Section {
                if availableEngines.isEmpty {
                    Text("settings.translation.engine.empty")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(selection: Binding(
                        get: { settings.readmeTranslationEngine },
                        set: { settings.readmeTranslationEngine = $0 }
                    )) {
                        ForEach(availableEngines) { engine in
                            Text(LocalizedStringKey(engine.displayNameKey)).tag(engine)
                        }
                    } label: {
                        Text("settings.translation.engine.default")
                    }
                }
            } header: {
                Text("settings.translation.section.engine")
            } footer: {
                Text("settings.translation.section.engine.footer")
            }

            Section {
                LabeledContent("settings.translation.system.title") {
                    Text("settings.translation.system.onDevice")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("settings.translation.openAISettings") {
                        NotificationCenter.default.post(
                            name: .starcatJumpToSettingsTab,
                            object: "ai"
                        )
                    }
                }
            } header: {
                Text("settings.translation.section.system")
            } footer: {
                Text("settings.translation.section.system.footer")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("settings.translation.google.description")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if isGoogleAPIKeyVisible {
                            TextField(
                                "settings.translation.google.apiKey.placeholder",
                                text: $googleAPIKey
                            )
                            .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField(
                                "settings.translation.google.apiKey.placeholder",
                                text: $googleAPIKey
                            )
                            .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            isGoogleAPIKeyVisible.toggle()
                        } label: {
                            Image(systemName: isGoogleAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(Text(isGoogleAPIKeyVisible
                            ? "settings.translation.google.apiKey.hide"
                            : "settings.translation.google.apiKey.show"))
                    }

                    HStack {
                        Text(googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "settings.translation.google.publicMode"
                            : "settings.translation.google.cloudMode")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("settings.translation.google.apiKey.save") {
                            saveGoogleAPIKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !hasStoredGoogleAPIKey)
                    }

                    HStack {
                        Spacer()
                        Button("settings.translation.google.openConsole") {
                            guard let url = URL(string: "https://console.cloud.google.com/apis/credentials") else { return }
                            openURL(url)
                        }
                    }
                }
            } header: {
                Text("settings.translation.section.google")
            } footer: {
                Text("settings.translation.section.google.footer")
            }
        }
        .formStyle(.grouped)
        .task(id: settings.effectiveReadmeTranslationLanguage) {
            await refreshEngines()
        }
        .task {
            loadGoogleAPIKey()
        }
    }

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

    /// Key 只写入 Starcat 的加密凭据文件；清空后自动回到无 Key 公开通道。
    private func saveGoogleAPIKey() {
        let trimmed = googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try KeychainManager.shared.deleteServiceAPIKey(
                    forService: GoogleTranslationClient.keychainServiceID
                )
            } else {
                try KeychainManager.shared.storeServiceAPIKey(
                    trimmed,
                    forService: GoogleTranslationClient.keychainServiceID
                )
            }
            googleAPIKey = trimmed
            hasStoredGoogleAPIKey = !trimmed.isEmpty
        } catch {
            AppLog.keychain.error(
                "Google Translation API key update failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadGoogleAPIKey() {
        googleAPIKey = (try? KeychainManager.shared.loadServiceAPIKey(
            forService: GoogleTranslationClient.keychainServiceID
        )) ?? ""
        hasStoredGoogleAPIKey = !googleAPIKey.isEmpty
    }
}

#Preview {
    TranslationSettingsTab()
        .environment(AppSettings.shared)
}
