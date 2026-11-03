//
//  ServicesSettingsView.swift
//  Starcat
//
//  设置页 → 服务 Tab：第三方 / 自建后端服务的 URL 配置。
//
//  设计要点：
//  - 用户可以为每个 `ThirdPartyService` 填入自部署后的 URL，留空 = 走 fly.io 生产默认值。
//  - 校验只做格式（http/https + host 非空），不发网络请求；「测试」走 `/api/v1/ping` 探测。
//  - 进入 Tab 时并发探测已保存的连接；手动「测试并保存」验证当前草稿，反馈均在操作行左侧。
//  - intro 行右侧汇总 pill 由全部 ping 聚合；点击跳转公开状态页（Better Stack status page）。
//  - 修改后**热生效**——通过 `AppDependencies.setServiceURL(_:for:)` 同时写
//    `AppSettings.customServiceURLs` 持久化 + 推送到对应 API actor `updateBaseURL`。
//  - 整页用 `ThirdPartyService.allCases` 自动渲染，新增服务时无需改本视图代码。
//
//  关键约束：
//  - 手动「测试并保存」成功后才提交草稿；进入页面的自动检测只验证，不保存。
//  - 编辑立即废弃旧请求，保存期间禁用编辑，避免端点和凭据来自不同输入版本。
//

import SwiftUI

struct ServicesSettingsTab: View {

    /// Better Stack 公开状态页；非 REST 端点，就近常量（见 AppEndpoints.swift 文件头约定）。
    private static let serviceStatusPageURL = URL(string: "https://starcat.betteruptime.com/")!

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    @State private var connections = Dictionary(uniqueKeysWithValues:
        ThirdPartyService.allCases.map { ($0.id, ServiceConnectionSettingsModel(service: $0)) }
    )

    private var healthResults: [String: HealthCheckOutcome] {
        connections.compactMapValues { $0.test.result }
    }

    private var probingServiceIDs: Set<String> {
        Set(connections.filter { $0.value.test.isTesting }.map(\.key))
    }

    private func connection(for service: ThirdPartyService) -> ServiceConnectionSettingsModel {
        connections[service.id]!
    }

    private var testableServices: [ThirdPartyService] {
        ThirdPartyService.allCases.filter { service in
            ThirdPartyService.validate(draft(for: service)).canPersist
        }
    }

    private var healthSummary: ServicesHealthSummary {
        ServicesHealthSummary.compute(
            testableServices: testableServices,
            results: healthResults,
            probingIDs: probingServiceIDs
        )
    }

    var body: some View {
        Form {
            SettingsPageIntroduction(
                title: "settings.navigation.item.customServices",
                systemImage: BusinessIcon.Symbol.services.rawValue,
                description: "settings.services.introduction.description",
                context: "settings.services.introduction.context"
            )

            Section {
                HStack(alignment: .center) {
                    Text("settings.services.intro")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    ServicesHealthSummaryBadge(
                        summary: healthSummary,
                        linkURL: Self.serviceStatusPageURL
                    )
                }
                .padding(.vertical, 2)
            }

            ForEach(ThirdPartyService.allCases) { service in
                serviceSection(for: service)
            }
        }
        .formStyle(.grouped)
        .task {
            loadDrafts()
            await testAllConnections()
        }
        .onDisappear {
            for model in connections.values { model.test.invalidate() }
        }
    }

    // MARK: - Per-service Section

    @ViewBuilder
    private func serviceSection(for service: ThirdPartyService) -> some View {
        let validation = ThirdPartyService.validate(draft(for: service))
        let test = connection(for: service).test
        let isProbing = test.isTesting

        Section {
            // 说明与「自托管」同行：左文案、右跳转，避免每个服务卡片顶部多占一行。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(service.descriptionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Link(destination: service.sourceCodeURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("settings.services.selfHost")
                    }
                    .font(.caption)
                }
                .help(Text("settings.services.selfHost.help"))
            }
            .padding(.vertical, 2)

            SettingsConnectionFieldRow(title: "settings.services.url") {
                SingleLineTextField(
                    text: Binding(
                        get: { draft(for: service) },
                        set: { newValue in
                            connection(for: service).draftURL = newValue
                        }
                    ),
                    prompt: String.l10n("settings.services.url.placeholder"),
                    onSubmit: { Task { await testConnection(for: service, savesOnSuccess: true) } }
                )
                .frame(height: ServiceFieldLayout.fieldHeight)
                .accessibilityLabel(Text("settings.services.url"))
            } trailing: {
                ResetIconButton(
                    help: Text("settings.services.reset.help"),
                    showsSuccessFeedback: false
                ) {
                    Task { await reset(service: service) }
                }
                .disabled(!hasCustomURL(for: service) && draft(for: service).isEmpty
                    && !hasCustomAPIKey(for: service) && apiKeyDraft(for: service).isEmpty)
            }

            apiKeyRow(for: service)
            captionRow(for: service, validation: validation)

            // 状态左 + Test 右（与设置页操作按钮惯例一致）。
            HStack {
                if isProbing {
                    ProgressView().controlSize(.small)
                    Text("settings.services.summary.checking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let message = test.errorMessage {
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let outcome = healthResults[service.id] {
                    ServiceHealthOutcomeLabel(
                        outcome: outcome,
                        colorForOutcome: colorForOutcome
                    )
                }
                Spacer()
                Button {
                    Task { await testConnection(for: service, savesOnSuccess: true) }
                } label: {
                    Text("settings.connection.testAndSave")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .fixedSize()
                .disabled(isProbing || !validation.canPersist)
            }
        } header: {
            SettingsSectionHeader(
                service.titleKey,
                iconSource: service.iconSource
            )
        }
        .disabled(test.isSaving)
    }

    private func apiKeyRow(for service: ThirdPartyService) -> some View {
        SettingsAPIKeyField(
            title: "settings.services.apiKey", text: apiKeyBinding(for: service),
            prompt: Text("settings.services.apiKey.placeholder")
        )
        .onSubmit { Task { await testConnection(for: service, savesOnSuccess: true) } }
    }

    /// 校验 / 当前生效 URL caption（ping 结果在底部 Test 行展示）。
    @ViewBuilder
    private func captionRow(
        for service: ThirdPartyService,
        validation: ServiceURLValidation
    ) -> some View {
        switch validation {
        case .invalid(let reasonKey):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(reasonKey)
            }
            .font(.caption)
            .foregroundStyle(.red)

        case .empty, .valid:
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Group {
                    if hasCustomURL(for: service) {
                        Text(String(
                            format: String.l10n("settings.services.effective"),
                            AppEndpoints.resolved(for: service).absoluteString
                        ))
                    } else {
                        Text("settings.services.effective.builtin")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    // MARK: - Field Row Layout

    private enum ServiceFieldLayout {
        static let fieldHeight: CGFloat = 22
    }

    // MARK: - Actions

    private func loadDrafts() {
        for service in ThirdPartyService.allCases {
            connection(for: service).load(
                url: settings.customServiceURL(for: service),
                apiKey: settings.customServiceAPIKey(for: service)
            )
        }
    }

    /// 进入 Tab 时并发检测草稿，但绝不隐式保存；只有手动操作才有提交权限。
    private func testAllConnections() async {
        await withTaskGroup(of: Void.self) { group in
            for service in testableServices {
                group.addTask {
                    await testConnection(for: service, retryTransientNetworkError: true)
                }
            }
        }
    }

    private func reset(service: ThirdPartyService) async {
        let succeeded = await connection(for: service).reset { url, key in
            try await saveConnection(url: url, key: key, for: service)
        }
        if succeeded { await testConnection(for: service) }
    }

    private func testConnection(
        for service: ThirdPartyService,
        retryTransientNetworkError: Bool = false,
        savesOnSuccess: Bool = false
    ) async {
        await connection(for: service).testConnection(
            savesOnSuccess: savesOnSuccess,
            retriesTransientError: retryTransientNetworkError,
            probe: { service, url, key in
                await dependencies.serviceHealthChecker.check(service: service, baseURL: url, apiKey: key)
            },
            save: { url, key in
                try await saveConnection(url: url, key: key, for: service)
            }
        )
    }

    /// 先确认凭据确实保存，再修改 URL；Keychain 失败不能把网络成功当成保存成功。
    private func saveConnection(url: URL?, key: String?, for service: ThirdPartyService) async throws {
        await dependencies.setServiceAPIKey(key, for: service)
        guard settings.customServiceAPIKey(for: service) == key else {
            throw ServiceSaveError.credentials
        }
        await dependencies.setServiceURL(url, for: service)
    }

    private enum ServiceSaveError: LocalizedError {
        case credentials
        var errorDescription: String? { String.l10n("settings.externalSearch.apiKey.saveFailed") }
    }

    // MARK: - Helpers

    private func draft(for service: ThirdPartyService) -> String {
        connection(for: service).draftURL
    }

    private func hasCustomURL(for service: ThirdPartyService) -> Bool {
        settings.customServiceURL(for: service) != nil
    }

    private func apiKeyDraft(for service: ThirdPartyService) -> String {
        connection(for: service).draftAPIKey
    }

    private func apiKeyBinding(for service: ThirdPartyService) -> Binding<String> {
        Binding(
            get: { connection(for: service).draftAPIKey },
            set: { newValue in
                connection(for: service).draftAPIKey = newValue
            }
        )
    }

    private func hasCustomAPIKey(for service: ThirdPartyService) -> Bool {
        settings.customServiceAPIKey(for: service) != nil
    }

    private func colorForOutcome(_ outcome: HealthCheckOutcome) -> Color {
        switch outcome {
        case .ok: return .green
        case .serviceMismatch: return .orange
        case .unauthorized: return .red
        case .serverError: return .orange
        case .networkError: return .red
        case .cancelled: return .secondary
        }
    }
}

#Preview("简体中文") {
    ServicesSettingsTab()
        .environment(AppSettings.shared)
        .environment(try! AppDependencies())
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .frame(width: 560, height: 600)
}

#Preview("English") {
    ServicesSettingsTab()
        .environment(AppSettings.shared)
        .environment(try! AppDependencies())
        .environment(\.locale, Locale(identifier: "en"))
        .frame(width: 560, height: 600)
}
