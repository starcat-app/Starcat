//
//  AITaskModelPicker.swift
//  Starcat
//
//  任务模型共用的原生分组菜单：服务商只出现在分组标题，选项只显示模型名称。
//  本组件只呈现调用方已过滤的目录；能力、验证规则及选择写入仍归原设置页负责。
//

import SwiftUI

/// 复用任务模型的菜单呈现，不持有配置副本，也不替调用方修复不可用的当前选择。
@MainActor
struct AITaskModelPicker: View {
    /// 服务商与模型组成完整身份；自定义当前项不能与目录里的同名模型共享 tag。
    struct Selection: Hashable {
        let providerID: String
        let modelName: String
        var isCustom = false
    }

    let title: LocalizedStringKey
    let profiles: [AIProviderProfile]
    @Binding var selection: Selection
    let providerDisplayName: String
    let availableModels: (AIProviderProfile) -> [AIModelDescriptor]

    /// 原生 Picker 保留当前值占位，避免目录刷新或自定义模型导致系统默认选中首项。
    var body: some View {
        let current = selection
        let currentIsAvailable = profiles.contains { profile in
            profile.id == current.providerID
                && availableModels(profile).contains { $0.name == current.modelName }
        }
        let currentName = current.isCustom
            ? current.modelName : AnthropicModelCatalog.displayName(forAPIID: current.modelName)
        let currentTitle = providerDisplayName.isEmpty
            ? currentName : "\(providerDisplayName) · \(currentName)"

        Picker(title, selection: $selection) {
            if current.isCustom || !currentIsAvailable {
                if currentName.isEmpty {
                    Text("settings.ai.task.noAvailableModel").tag(current)
                } else {
                    Text(verbatim: currentName).tag(current)
                }
            }
            ForEach(profiles) { provider in
                let models = availableModels(provider)
                if !models.isEmpty {
                    Section {
                        ForEach(models) { model in
                            Text(verbatim: AnthropicModelCatalog.displayName(forAPIID: model.name))
                                .tag(Selection(providerID: provider.id, modelName: model.name))
                        }
                    } header: {
                        Text(verbatim: provider.displayName)
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .lineLimit(1)
        .frame(maxWidth: 340, alignment: .trailing)
        .help(Text(verbatim: currentTitle))
    }
}
