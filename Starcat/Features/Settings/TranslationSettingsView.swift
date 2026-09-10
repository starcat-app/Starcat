//
//  TranslationSettingsView.swift
//  Starcat
//
//  「翻译服务」设置页：默认引擎 + 系统翻译说明。
//  AI 的 Provider / Prompt 仍在 AI 设置，这里只选「用谁译」。
//

import SwiftUI

struct TranslationSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var availableEngines: [ReadmeTranslationEngine] = []

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
        }
        .formStyle(.grouped)
        .task(id: settings.effectiveReadmeTranslationLanguage) {
            await refreshEngines()
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
}

#Preview {
    TranslationSettingsTab()
        .environment(AppSettings.shared)
}
