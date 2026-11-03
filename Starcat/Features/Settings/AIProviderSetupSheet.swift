//
//  AIProviderSetupSheet.swift
//  Starcat
//
//  新增与编辑服务商共用的原生表单：编辑固定服务商类型，未验证草稿不影响后方页面。
//  本视图只组织输入和反馈，验证、保存及取消生命周期仍由原会话对象与宿主负责。
//

import SwiftUI

/// 服务商配置表单。宿主同步提交 Keychain 与配置，失败时保留弹窗和输入。
@MainActor
struct AIProviderSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var viewModel: AIProviderSetupViewModel
    @State private var isAPIKeyVisible = false
    @FocusState private var focusedField: InputField?
    let onAdd: AIProviderSetupViewModel.Addition

    private enum InputField: Hashable {
        case displayName, baseURL, apiKey
    }

    /// 借用宿主持有的会话，保持原有关闭窗口时立即取消验证的边界。
    init(viewModel: AIProviderSetupViewModel, onAdd: @escaping AIProviderSetupViewModel.Addition) {
        self.viewModel = viewModel
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Form {
                Section {
                    fieldRow(
                        "settings.ai.provider.setup.provider.title",
                        description: "settings.ai.provider.setup.provider.description"
                    ) {
                        Group {
                            if viewModel.isEditing {
                                // 编辑固定原服务商类型，不允许套用另一协议覆盖原配置。
                                Label {
                                    Text(viewModel.profile.provider.displayName)
                                } icon: {
                                    AIProviderIconView(provider: viewModel.profile.provider, size: 14)
                                }
                            } else {
                                providerPicker
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    fieldRow(
                        "settings.ai.provider.displayName",
                        description: "settings.ai.provider.setup.displayName.description"
                    ) {
                        TextField("settings.ai.provider.displayName", text: $viewModel.displayName)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .displayName)
                            .accessibilityLabel("settings.ai.provider.displayName")
                    }
                    fieldRow(
                        "Base URL",
                        description: "settings.ai.provider.setup.baseURL.description"
                    ) {
                        TextField("Base URL", text: $viewModel.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .baseURL)
                            .accessibilityLabel("Base URL")
                    }
                    if viewModel.profile.provider != .ollama {
                        fieldRow("API Key", description: apiKeyDescription) {
                            apiKeyInput
                        }
                    }
                }
            }
            // 此独立 sheet 最多四项固定输入，使用系统不滚动的 columns 表单例外；
            // grouped 适合可滚动的设置页，固定其高度会在此造成裁切或大片留白。
            .formStyle(.columns)
            .controlSize(.regular)
            .fixedSize(horizontal: false, vertical: true)

            if viewModel.profile.provider == .anthropic {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SettingsCaptionASCIILinks.attributedString(
                        from: String.l10n("settings.ai.provider.anthropic.baseURLHint")
                    ))
                    .tint(.accentColor)
                    Text("settings.ai.provider.anthropic.embeddingUnsupported")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = viewModel.errorMessage {
                Label {
                    Text(verbatim: error)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .help(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { viewModel.cancel() }
    }

    /// 标题使用紧凑的系统层级，不为配置任务增加装饰性图标底板。
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(titleKey)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(Text(titleKey))
                Spacer(minLength: 8)
                SheetCloseButton(action: close)
            }
            Text(subtitleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(Text(subtitleKey))
        }
    }

    private var titleKey: LocalizedStringKey {
        viewModel.isEditing ? "settings.ai.provider.edit.title" : "settings.ai.provider.setup.title"
    }

    private var subtitleKey: LocalizedStringKey {
        viewModel.isEditing ? "settings.ai.provider.edit.subtitle" : "settings.ai.provider.setup.subtitle"
    }

    private var submitKey: LocalizedStringKey {
        viewModel.isEditing ? "settings.ai.provider.edit.testAndSave" : "settings.ai.provider.setup.testAndAdd"
    }

    private var apiKeyDescription: LocalizedStringKey {
        if viewModel.hasExistingAPIKey { return "settings.ai.provider.edit.keepAPIKey" }
        return viewModel.profile.provider.allowsEmptyAPIKey
            ? "settings.ai.provider.setup.optionalAPIKey" : "settings.ai.provider.setup.apiKey.description"
    }

    /// 系统菜单负责控件尺寸与唯一的下拉指示器，类型切换仍交给原草稿会话处理。
    private var providerPicker: some View {
        Picker("settings.ai.provider.setup.provider.title", selection: Binding(
            get: { viewModel.profile.provider },
            set: { viewModel.selectProvider($0) }
        )) {
            ForEach(AIServiceProvider.userSelectableCases) { provider in
                Label {
                    Text(provider.displayName)
                } icon: {
                    AIProviderIconView(provider: provider, size: 14)
                }
                .tag(provider)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(Text("settings.ai.provider.setup.provider.title"))
        .help(Text(viewModel.profile.provider.displayName))
    }

    /// 明文和密文只切换视图，始终使用同一个草稿绑定，不写入全局配置。
    private var apiKeyInput: some View {
        HStack(spacing: 8) {
            Group {
                if isAPIKeyVisible {
                    TextField(apiKeyPlaceholder, text: $viewModel.apiKey)
                } else {
                    SecureField(apiKeyPlaceholder, text: $viewModel.apiKey)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .apiKey)
            .accessibilityLabel("API Key")
            .frame(maxWidth: .infinity)

            SettingsActionIconButton(
                title: isAPIKeyVisible ? "settings.externalSearch.apiKey.hide" : "settings.externalSearch.apiKey.show",
                systemImage: isAPIKeyVisible ? "eye.slash" : "eye"
            ) {
                isAPIKeyVisible.toggle()
                focusedField = .apiKey
            }
        }
    }

    private var apiKeyPlaceholder: LocalizedStringKey {
        viewModel.hasExistingAPIKey ? "settings.ai.provider.edit.keepAPIKey" : "API Key"
    }

    /// 操作使用文字表达含义；进度留在按钮外，提交标题和宽度不随测试状态变化。
    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                Button("settings.ai.provider.setup.presets.applyDefaults", action: applyProviderDefaults)
            } label: {
                Text("settings.ai.provider.setup.presets.title")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize()
            .accessibilityLabel(Text("settings.ai.provider.setup.presets.title"))
            .help(Text("settings.ai.provider.setup.presets.help"))
            .disabled(viewModel.isTesting)

            if viewModel.isTesting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("settings.ai.provider.setup.testing"))
            }
            Spacer(minLength: 8)

            Button("general.cancel", action: close)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                Task {
                    if await viewModel.testAndAdd(onAdd: onAdd) {
                        dismiss()
                    }
                }
            } label: {
                Text(submitKey)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canTest)
        }
    }

    /// 系统双列表单统一对齐标签和值，并按可见输入的实际高度撑开；说明通过提示展示。
    private func fieldRow<Field: View>(
        _ label: LocalizedStringKey,
        description: LocalizedStringKey,
        @ViewBuilder field: () -> Field
    ) -> some View {
        LabeledContent {
            field()
                // 标签由 LabeledContent 提供，隐藏输入框自带标签，避免重复显示和对齐冲突。
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint(Text(description))
        } label: {
            Text(label)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(Text(label) + Text(verbatim: "\n") + Text(description))
        }
        .frame(minHeight: 32)
    }

    /// 示例只回填当前类型的默认名称和地址；不更换类型、ID 或用户已输入的 Key。
    private func applyProviderDefaults() {
        viewModel.displayName = viewModel.profile.provider.defaultProfileName
        viewModel.baseURL = viewModel.profile.provider.defaultBaseURL
    }

    /// 先失效验证会话再关闭，覆盖右上角、取消和系统取消快捷键三种入口。
    private func close() {
        viewModel.cancel()
        dismiss()
    }
}
