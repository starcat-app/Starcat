//
//  ServicesSettingsView.swift
//  Starcat
//
//  设置页 → 服务 Tab：第三方 / 自建后端服务的 URL 配置。
//
//  设计要点：
//  - 用户可以为每个 `ThirdPartyService` 填入自部署后的 URL，留空 = 走 fly.io 生产默认值。
//  - 校验只做格式（http/https + host 非空），不发网络请求；「测试」走 `/api/v1/ping` 探测。
//  - 进入 Tab 时并发对四个服务各跑一次 ping（与手动点「测试」同逻辑），结果落在各卡片 Test 行左侧。
//  - intro 行右侧汇总 pill 由四路 ping 聚合；点击跳转公开状态页（Better Stack status page）。
//  - 修改后**热生效**——通过 `AppDependencies.setServiceURL(_:for:)` 同时写
//    `AppSettings.customServiceURLs` 持久化 + 推送到对应 API actor `updateBaseURL`。
//  - 整页用 `ThirdPartyService.allCases` 自动渲染，新增服务时无需改本视图代码。
//
//  关键约束：
//  - 编辑状态走 `@State` 草稿（`draftURLs` / `draftAPIKeys`），**点「测试」时统一落盘**
//    （R-03 2026-06-11 dong4j 拍板：保存合并进测试按钮）。
//  - `serviceHealthChecker` 结果缓存在 `healthResults` 里，仅当前会话有效。
//

import SwiftUI

struct ServicesSettingsTab: View {

    /// Better Stack 公开状态页；非 REST 端点，就近常量（见 AppEndpoints.swift 文件头约定）。
    private static let serviceStatusPageURL = URL(string: "https://starcat.betteruptime.com/")!

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    @State private var draftURLs: [String: String] = [:]
    @State private var draftAPIKeys: [String: String] = [:]
    @State private var revealAPIKey: [String: Bool] = [:]
    @State private var healthResults: [String: HealthCheckOutcome] = [:]
    /// 正在进行 ping 的服务 id（支持进入页并发四路探测）。
    @State private var probingServiceIDs: Set<String> = []
    @State private var savingServiceID: String?

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
    }

    // MARK: - Per-service Section

    @ViewBuilder
    private func serviceSection(for service: ThirdPartyService) -> some View {
        let validation = ThirdPartyService.validate(draft(for: service))
        let isProbing = probingServiceIDs.contains(service.id)

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

            serviceLabeledFieldRow(labelKey: "settings.services.url") {
                SingleLineTextField(
                    text: Binding(
                        get: { draft(for: service) },
                        set: { newValue in draftURLs[service.id] = newValue }
                    ),
                    prompt: String.l10n("settings.services.url.placeholder"),
                    onSubmit: { Task { await testConnection(for: service) } }
                )
                .frame(width: ServiceFieldLayout.fieldWidth, height: ServiceFieldLayout.fieldHeight)
                .accessibilityLabel(Text("settings.services.url"))
            } trailingIcon: {
                serviceFieldIconButton(
                    systemName: "arrow.counterclockwise",
                    helpKey: "settings.services.reset.help",
                    disabled: !hasCustomURL(for: service) && draft(for: service).isEmpty
                        && !hasCustomAPIKey(for: service) && apiKeyDraft(for: service).isEmpty
                ) {
                    Task { await reset(service: service) }
                }
            }

            apiKeyRow(for: service)
            captionRow(for: service, validation: validation)

            // 状态左 + Test 右（与设置页操作按钮惯例一致）。
            HStack {
                if isProbing {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("settings.services.summary.checking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let outcome = healthResults[service.id] {
                    ServiceHealthOutcomeLabel(
                        outcome: outcome,
                        colorForOutcome: colorForOutcome
                    )
                }
                Spacer()
                Button {
                    Task { await testConnection(for: service) }
                } label: {
                    HStack(spacing: 4) {
                        if isProbing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "network")
                                .font(.system(size: 15, weight: .medium))
                        }
                        Text("settings.services.testConnection")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isProbing || !validation.canPersist)
            }
        } header: {
            SettingsSectionHeader(
                service.titleKey,
                systemImage: service.systemImage,
                style: .prominent
            )
        }
    }

    @ViewBuilder
    private func apiKeyRow(for service: ThirdPartyService) -> some View {
        let isReveal = revealAPIKey[service.id] ?? false

        serviceLabeledFieldRow(labelKey: "settings.services.apiKey") {
            SingleLineTextField(
                text: apiKeyBinding(for: service),
                isSecure: !isReveal,
                prompt: String.l10n("settings.services.apiKey.placeholder"),
                onSubmit: { Task { await testConnection(for: service) } }
            )
            .id(isReveal)
            .frame(width: ServiceFieldLayout.fieldWidth, height: ServiceFieldLayout.fieldHeight)
            .accessibilityLabel(Text("settings.services.apiKey"))
        } trailingIcon: {
            serviceFieldIconButton(
                systemName: isReveal ? "eye.slash" : "eye",
                helpKey: isReveal ? "settings.services.apiKey.hide" : "settings.services.apiKey.reveal"
            ) {
                revealAPIKey[service.id] = !isReveal
            }
        }
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
        static let labelWidth: CGFloat = 72
        static let fieldWidth: CGFloat = 340
        static let fieldHeight: CGFloat = 22
        static let iconSlotSize: CGFloat = 28
        static let rowSpacing: CGFloat = 8
    }

    @ViewBuilder
    private func serviceLabeledFieldRow<Field: View, Trailing: View>(
        labelKey: LocalizedStringKey,
        @ViewBuilder field: () -> Field,
        @ViewBuilder trailingIcon: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: ServiceFieldLayout.rowSpacing) {
            Text(labelKey)
                .font(.body)
                .frame(width: ServiceFieldLayout.labelWidth, alignment: .leading)
            Spacer(minLength: ServiceFieldLayout.rowSpacing)
            field()
            trailingIcon()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func serviceFieldIconButton(
        systemName: String,
        helpKey: LocalizedStringKey,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(
                    width: ServiceFieldLayout.iconSlotSize,
                    height: ServiceFieldLayout.iconSlotSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(Text(helpKey))
        .accessibilityLabel(Text(helpKey))
    }

    // MARK: - Actions

    private func loadDrafts() {
        var loadedURLs: [String: String] = [:]
        var loadedKeys: [String: String] = [:]
        for service in ThirdPartyService.allCases {
            loadedURLs[service.id] = settings.customServiceURL(for: service) ?? ""
            loadedKeys[service.id] = settings.customServiceAPIKey(for: service) ?? ""
        }
        if draftURLs.isEmpty {
            draftURLs = loadedURLs
        }
        if draftAPIKeys.isEmpty {
            draftAPIKeys = loadedKeys
        }
    }

    /// 进入 Tab 时对全部可探测服务并发跑一次 ping（等同用户逐一点「测试」）。
    private func testAllConnections() async {
        await withTaskGroup(of: Void.self) { group in
            for service in testableServices {
                group.addTask {
                    await testConnection(for: service, retryTransientNetworkError: true)
                }
            }
        }
    }

    private func save(
        service: ThirdPartyService,
        validation: ServiceURLValidation,
        clearHealthResult: Bool = true
    ) async {
        guard validation.canPersist else { return }
        savingServiceID = service.id
        defer { savingServiceID = nil }

        let urlToPersist: URL?
        switch validation {
        case .valid(let url):
            let normalized = service.normalizedBaseURL(url)
            urlToPersist = normalized
            draftURLs[service.id] = normalized.absoluteString
        case .empty:
            urlToPersist = nil
        case .invalid:
            return
        }

        await dependencies.setServiceURL(urlToPersist, for: service)
        if clearHealthResult {
            healthResults[service.id] = nil
        }
    }

    private func reset(service: ThirdPartyService) async {
        savingServiceID = service.id
        defer { savingServiceID = nil }
        await dependencies.resetServiceURL(for: service)
        await dependencies.resetServiceAPIKey(for: service)
        draftURLs[service.id] = ""
        draftAPIKeys[service.id] = ""
        healthResults[service.id] = nil
        // 重置回内置服务后立刻 re-probe，否则汇总 pill 会因缺一项结果卡在 Checking。
        await testConnection(for: service)
    }

    private func saveAPIKey(for service: ThirdPartyService, clearHealthResult: Bool = true) async {
        savingServiceID = service.id
        defer { savingServiceID = nil }
        let trimmed = apiKeyDraft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        await dependencies.setServiceAPIKey(trimmed.isEmpty ? nil : trimmed, for: service)
        if clearHealthResult {
            healthResults[service.id] = nil
        }
    }

    private func testConnection(
        for service: ThirdPartyService,
        retryTransientNetworkError: Bool = false
    ) async {
        probingServiceIDs.insert(service.id)
        defer { probingServiceIDs.remove(service.id) }

        let validation = ThirdPartyService.validate(draft(for: service))
        let baseURL: URL
        switch validation {
        case .valid(let url):
            baseURL = service.normalizedBaseURL(url)
        case .empty:
            baseURL = service.productionURL
        case .invalid:
            return
        }

        if validation.canPersist, isDraftDirty(for: service) {
            await save(service: service, validation: validation, clearHealthResult: false)
        }
        if isAPIKeyDraftDirty(for: service) {
            await saveAPIKey(for: service, clearHealthResult: false)
        }

        let trimmedDraftKey = apiKeyDraft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        let probeKey: String?
        if !trimmedDraftKey.isEmpty {
            probeKey = trimmedDraftKey
        } else if let saved = settings.customServiceAPIKey(for: service), !saved.isEmpty {
            probeKey = saved
        } else {
            probeKey = StarcatAPIKeyDefaults.productionKeyOrNil(for: service)
        }

        var outcome = await dependencies.serviceHealthChecker.check(
            service: service,
            baseURL: baseURL,
            apiKey: probeKey
        )

        // 只给进入设置页的自动检测一次轻量重试：fly.io 冷启动 / TLS 抖动 / timeout
        // 常见于首轮并发探测；手动测试仍保持单次请求，避免用户等待时间被隐式拉长。
        if retryTransientNetworkError, outcome.shouldRetryForAutomaticProbe, !Task.isCancelled {
            outcome = await dependencies.serviceHealthChecker.check(
                service: service,
                baseURL: baseURL,
                apiKey: probeKey
            )
        }

        guard !outcome.isCancelledProbe, !Task.isCancelled else { return }
        healthResults[service.id] = outcome
    }

    // MARK: - Helpers

    private func draft(for service: ThirdPartyService) -> String {
        draftURLs[service.id] ?? ""
    }

    private func hasCustomURL(for service: ThirdPartyService) -> Bool {
        settings.customServiceURL(for: service) != nil
    }

    private func isDraftDirty(for service: ThirdPartyService) -> Bool {
        let persisted = settings.customServiceURL(for: service) ?? ""
        let draftValue = draft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        return persisted != draftValue
    }

    private func apiKeyDraft(for service: ThirdPartyService) -> String {
        draftAPIKeys[service.id] ?? ""
    }

    private func apiKeyBinding(for service: ThirdPartyService) -> Binding<String> {
        Binding(
            get: { draftAPIKeys[service.id] ?? "" },
            set: { newValue in draftAPIKeys[service.id] = newValue }
        )
    }

    private func hasCustomAPIKey(for service: ThirdPartyService) -> Bool {
        settings.customServiceAPIKey(for: service) != nil
    }

    private func isAPIKeyDraftDirty(for service: ThirdPartyService) -> Bool {
        let persisted = settings.customServiceAPIKey(for: service) ?? ""
        let draftValue = apiKeyDraft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        return persisted != draftValue
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
