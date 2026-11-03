//
//  AIModelManagementSheet.swift
//  Starcat
//
//  已发现模型管理的单一展示入口：直接复用既有模型列表、能力选择与参数编辑组件。
//  弹窗只保存服务商 ID，实时读取配置；启用状态及参数仍由宿主的原绑定即时保存。
//

import SwiftUI

/// 模型管理弹窗。不复制服务商快照，避免修改模型开关后列表仍显示进入弹窗时的旧状态。
@MainActor
struct AIModelManagementSheet: View {
    let providerID: String
    let enabledBinding: (AIModelDescriptor) -> Binding<Bool>
    let capabilityBinding: (AIModelDescriptor) -> Binding<AIModelCapability>
    let parametersBinding: (AIModelDescriptor) -> Binding<AIModelParameters?>

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// AppSettings 是配置真源；列表内即时写入后重新取得当前 profile，保留观察依赖。
    private var profile: AIProviderProfile? {
        settings.aiProviderProfiles.first { $0.id == providerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.ai.models.management.section")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.ai.models.management.section"))
                    if let profile {
                        Text(verbatim: profile.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(profile.displayName)
                    }
                }
                Spacer(minLength: 8)
                SheetCloseButton(action: close)
            }

            Divider()

            if let profile, !profile.models.isEmpty {
                // 原组件负责列表尺寸、分页及参数弹出层；不再套 Form 或第二层滚动容器。
                AIModelListView(
                    profile: profile,
                    enabledBinding: enabledBinding,
                    capabilityBinding: capabilityBinding,
                    parametersBinding: parametersBinding
                )
                .id(profile.id)
            } else {
                Text("settings.ai.discoveredModels.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Spacer(minLength: 0)
                Button("settings.ai.models.prompt.done", action: close)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 列表沿用即时保存，完成与关闭只结束展示，不新增提交或撤销路径。
    private func close() {
        dismiss()
    }
}
