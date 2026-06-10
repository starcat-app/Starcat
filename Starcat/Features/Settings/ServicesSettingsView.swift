//
//  ServicesSettingsView.swift
//  Starcat
//
//  设置页 → 服务 Tab：第三方 / 自建后端服务的 URL 配置。
//
//  设计要点：
//  - 用户可以为每个 `ThirdPartyService` 填入自部署后的 URL，留空 = 走 fly.io 生产默认值。
//  - 校验只做格式（http/https + host 非空），不发网络请求；想测连接走"测试连接"按钮。
//  - 修改后**热生效**——通过 `AppDependencies.setServiceURL(_:for:)` 同时写
//    `AppSettings.customServiceURLs` 持久化 + 推送到对应 API actor `updateBaseURL`，
//    不需要重启 App。
//  - 整页用 `ThirdPartyService.allCases` 自动渲染，新增服务时无需改本视图代码。
//
//  关键约束：
//  - 编辑状态走 `@State` 草稿（`draftURLs: [String: String]`），失焦或显式"保存"才写盘。
//    这是为了避免每个 keypress 都触发 didSet → 持久化 + actor 热更新的链路，体验/性能两不好。
//  - 测试连接按钮使用 actor `serviceHealthChecker`，结果缓存在 `healthResults: [String: HealthCheckOutcome]`
//    里，仅当前会话有效（关 Settings 窗口就清，避免误导）。
//

import SwiftUI
import AppKit

struct ServicesSettingsTab: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    /// 每个服务的编辑草稿；键 = `ThirdPartyService.rawValue`。
    /// 值是用户当前在 TextField 里看到的字符串（可能未保存）。
    @State private var draftURLs: [String: String] = [:]
    /// 每个服务的 API Key 草稿（R-01 v1.2 BYOK，2026-06-10 加）。
    /// 值是用户在 SecureField 里看到的字符串（可能未保存）。空字符串 = 留空走 production 默认。
    @State private var draftAPIKeys: [String: String] = [:]
    /// 控制每个服务的 API Key 是否以明文显示（默认 false = 黑点遮蔽）。
    @State private var revealAPIKey: [String: Bool] = [:]
    /// 每个服务最近一次"测试连接"结果。
    @State private var healthResults: [String: HealthCheckOutcome] = [:]
    /// 当前正在测试连接的 service id（用于按钮 spinner + 禁用）。
    @State private var probingServiceID: String?
    /// 当前正在保存（写持久化 + 推送 actor）的 service id。
    @State private var savingServiceID: String?

    var body: some View {
        Form {
            Section {
                Text("settings.services.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }

            ForEach(ThirdPartyService.allCases) { service in
                serviceSection(for: service)
            }
        }
        .formStyle(.grouped)
        .task {
            // 进入页面时把已持久化的 URL 拉到草稿里。
            loadDrafts()
        }
    }

    // MARK: - Per-service Section

    @ViewBuilder
    private func serviceSection(for service: ThirdPartyService) -> some View {
        let validation = ThirdPartyService.validate(draft(for: service))
        let isDirty = isDraftDirty(for: service)
        let isProbing = probingServiceID == service.id
        let isSaving = savingServiceID == service.id

        Section {
            // 标题 + 描述 + 跳源码链接
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: service.systemImage)
                        .foregroundStyle(service.accentColor)
                        .font(.headline)
                    Text(service.titleKey)
                        .font(.headline)
                    Spacer()
                    Link(destination: service.sourceCodeURL) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("settings.services.selfHost")
                        }
                        .font(.caption)
                    }
                    .help(Text("settings.services.selfHost.help"))
                }
                Text(service.descriptionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            // URL 输入框 + 重置按钮
            HStack(spacing: 8) {
                TextField(
                    "settings.services.url",
                    text: Binding(
                        get: { draft(for: service) },
                        set: { newValue in draftURLs[service.id] = newValue }
                    ),
                    prompt: Text(service.productionURL.absoluteString)
                )
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onSubmit {
                    Task { await save(service: service, validation: validation) }
                }

                Button {
                    Task { await save(service: service, validation: validation) }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("general.save")
                    }
                }
                .disabled(!isDirty || !validation.canPersist || isSaving)
                .help(Text("settings.services.save.help"))

                Button {
                    Task { await reset(service: service) }
                } label: {
                    Text("general.reset")
                }
                .disabled(!hasCustomURL(for: service) && draft(for: service).isEmpty
                          && !hasCustomAPIKey(for: service) && apiKeyDraft(for: service).isEmpty)
                .help(Text("settings.services.reset.help"))
            }

            // R-01 v1.2 BYOK API Key 输入行（2026-06-10 加）：
            // - SecureField + 显示/隐藏切换（眼睛图标）
            // - 留空 = 走 production 默认 Key（编译期注入的 baked-in 值或 BYOK-only 模式 nil）
            // - 失焦 / 显式保存才落 keychain（与 URL 草稿同节奏，避免每个 keypress 写 keychain）
            apiKeyRow(for: service)

            // 校验失败 / 当前生效 / 测试结果 caption
            captionRow(for: service, validation: validation)

            // 测试连接按钮：状态左 + Spacer + 按钮右（按钮统一右对齐，与设置面板内
            // 操作型按钮的视觉惯例一致；状态文本贴近左侧 URL 输入框便于关联阅读）。
            HStack {
                if let outcome = healthResults[service.id], !isProbing {
                    HStack(spacing: 4) {
                        Image(systemName: outcome.systemImage)
                            .foregroundStyle(colorForOutcome(outcome))
                        Text(outcome.titleKey)
                            .foregroundStyle(colorForOutcome(outcome))
                            .font(.caption)
                        Text(verbatim: outcome.subtitle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
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
                        }
                        Text("settings.services.testConnection")
                    }
                }
                .disabled(isProbing || !validation.canPersist)
            }
        }
    }

    /// API Key BYOK 输入行（R-01 v1.2 2026-06-10）。
    ///
    /// 设计：SecureField 默认黑点遮蔽 → 眼睛按钮切到明文 TextField → 保存 / 重置按钮。
    /// 与 URL 草稿同节奏：失焦或显式点保存才落 keychain，避免 keypress 高频写。
    @ViewBuilder
    private func apiKeyRow(for service: ThirdPartyService) -> some View {
        let isReveal = revealAPIKey[service.id] ?? false
        let isDirty = isAPIKeyDraftDirty(for: service)
        let isSaving = savingServiceID == service.id

        HStack(spacing: 8) {
            // SecureField（黑点）/ TextField（明文）二选一，由 reveal 控制
            Group {
                if isReveal {
                    TextField(
                        "settings.services.apiKey",
                        text: apiKeyBinding(for: service),
                        prompt: Text("settings.services.apiKey.placeholder")
                    )
                } else {
                    SecureField(
                        "settings.services.apiKey",
                        text: apiKeyBinding(for: service),
                        prompt: Text("settings.services.apiKey.placeholder")
                    )
                }
            }
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
            .onSubmit {
                Task { await saveAPIKey(for: service) }
            }

            // 显示/隐藏 toggle（眼睛图标）
            Button {
                revealAPIKey[service.id] = !isReveal
            } label: {
                Image(systemName: isReveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(isReveal ? "settings.services.apiKey.hide" : "settings.services.apiKey.reveal"))

            // 保存 API Key 按钮
            Button {
                Task { await saveAPIKey(for: service) }
            } label: {
                Text("general.save")
            }
            .disabled(!isDirty || isSaving)
            .help(Text("settings.services.apiKey.save.help"))
        }
    }

    /// 校验 / 生效 / 提示文案，单行 caption。
    @ViewBuilder
    private func captionRow(for service: ThirdPartyService, validation: ServiceURLValidation) -> some View {
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
                    .foregroundStyle(.tertiary)
                // 显示"当前生效"的 URL——已保存生效值（AppEndpoints.resolved(for:)），
                // 不是 draft；这样能让用户看到"我保存前 vs 保存后"的差别。
                Text(String(format: String(localized: "settings.services.effective"), AppEndpoints.resolved(for: service).absoluteString))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Actions

    /// 把持久化字典拉到草稿里。draft 为空字符串表示"留空（用默认）"。
    private func loadDrafts() {
        var loadedURLs: [String: String] = [:]
        var loadedKeys: [String: String] = [:]
        for service in ThirdPartyService.allCases {
            loadedURLs[service.id] = settings.customServiceURL(for: service) ?? ""
            loadedKeys[service.id] = settings.customServiceAPIKey(for: service) ?? ""
        }
        // 仅在尚无草稿时填充，避免覆盖正在编辑的内容（虽然 task 一般只跑一次）。
        if draftURLs.isEmpty {
            draftURLs = loadedURLs
        }
        if draftAPIKeys.isEmpty {
            draftAPIKeys = loadedKeys
        }
    }

    /// 保存当前草稿。`validation` 必须是 `.valid` 或 `.empty`，调用方已检查 `canPersist`。
    ///
    /// - Parameter clearHealthResult: 显式 "保存" 按钮触发的保存（默认 true）会清掉
    ///   旧的健康检查结果——因为 URL 已变，旧结果与新 URL 无关，留着误导。
    ///   "测试连接 → ok → 自动保存"路径传 false，保留刚拿到的成功结果给用户看到。
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
        case .valid(let url): urlToPersist = url
        case .empty:          urlToPersist = nil
        case .invalid:        return // 上面 guard 已挡，理论上到不了这里
        }

        await dependencies.setServiceURL(urlToPersist, for: service)
        if clearHealthResult {
            healthResults[service.id] = nil
        }
    }

    /// 重置某服务的 URL + API Key（双清持久化 + 草稿，回退到 production 默认）。
    private func reset(service: ThirdPartyService) async {
        savingServiceID = service.id
        defer { savingServiceID = nil }
        await dependencies.resetServiceURL(for: service)
        await dependencies.resetServiceAPIKey(for: service)
        draftURLs[service.id] = ""
        draftAPIKeys[service.id] = ""
        healthResults[service.id] = nil
    }

    /// 保存 API Key 草稿到 Keychain + 推送到 API actor 热更新。
    private func saveAPIKey(for service: ThirdPartyService) async {
        savingServiceID = service.id
        defer { savingServiceID = nil }
        let trimmed = apiKeyDraft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        await dependencies.setServiceAPIKey(trimmed.isEmpty ? nil : trimmed, for: service)
        // URL 改动的旧 health result 与新 key 无关，清掉避免误导
        healthResults[service.id] = nil
    }

    /// 测试连接。用当前**草稿**的 URL（如果合法），否则用"当前生效"URL（已保存的或默认）。
    /// 这样用户即使没点保存，也能先测一下新地址是否通。
    ///
    /// **R-01 v1.2 2026-06-10 扩展**：测试连接现在双 step（healthz + Bearer 鉴权探测）。
    /// 用 draft 中的 API Key（未填则走 `StarcatAPIKeyResolver.resolve` 解析的当前生效值）测鉴权，
    /// 让用户在保存前能验证 BYOK Key 是否被后端接受。
    ///
    /// **测试通过 + 草稿与持久化值不一致 → 自动保存**（2026-06-08 dong4j 反馈，2026-06-10 扩到 API Key）。
    /// 省去用户"测一下 → 点保存"的二次点击。`save` 传 `clearHealthResult: false`
    /// 保留刚拿到的 ✓ Reachable 状态。
    private func testConnection(for service: ThirdPartyService) async {
        probingServiceID = service.id
        defer { probingServiceID = nil }

        let validation = ThirdPartyService.validate(draft(for: service))
        let baseURL: URL
        switch validation {
        case .valid(let url): baseURL = url
        case .empty:          baseURL = service.productionURL
        case .invalid:        return // 上面 disabled 应已挡，安全兜底
        }

        // 鉴权 key 解析顺序：草稿（用户正在编辑） → 已配置 BYOK → production 默认（编译期注入）
        // 三段都没值 → nil（让后端必返 401，UI 显示 unauthorized 引导用户去填 Key）
        let trimmedDraftKey = apiKeyDraft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        let probeKey: String?
        if !trimmedDraftKey.isEmpty {
            probeKey = trimmedDraftKey
        } else if let saved = settings.customServiceAPIKey(for: service), !saved.isEmpty {
            probeKey = saved
        } else {
            probeKey = StarcatAPIKeyDefaults.productionKeyOrNil
        }

        let outcome = await dependencies.serviceHealthChecker.check(
            service: service,
            baseURL: baseURL,
            apiKey: probeKey
        )
        healthResults[service.id] = outcome

        // 自动保存路径：测试通过 → 把 dirty 的 URL / API Key 一起落盘（按需）。
        if case .ok = outcome {
            if case .valid = validation, isDraftDirty(for: service) {
                await save(service: service, validation: validation, clearHealthResult: false)
            }
            if isAPIKeyDraftDirty(for: service) {
                await dependencies.setServiceAPIKey(
                    trimmedDraftKey.isEmpty ? nil : trimmedDraftKey,
                    for: service
                )
            }
        }
    }

    // MARK: - Helpers

    private func draft(for service: ThirdPartyService) -> String {
        draftURLs[service.id] ?? ""
    }

    private func hasCustomURL(for service: ThirdPartyService) -> Bool {
        settings.customServiceURL(for: service) != nil
    }

    /// 草稿是否与已持久化值不同——决定"保存"按钮是否高亮。
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

    /// API Key 草稿与持久化值是否不同——决定其"保存"按钮是否高亮。
    private func isAPIKeyDraftDirty(for service: ThirdPartyService) -> Bool {
        let persisted = settings.customServiceAPIKey(for: service) ?? ""
        let draftValue = apiKeyDraft(for: service).trimmingCharacters(in: .whitespacesAndNewlines)
        return persisted != draftValue
    }

    private func colorForOutcome(_ outcome: HealthCheckOutcome) -> Color {
        switch outcome {
        case .ok: return .green
        case .unauthorized: return .red
        case .authProbeError, .reachableButError: return .orange
        case .unreachable: return .red
        }
    }
}

#Preview("简体中文") {
    ServicesSettingsTab()
        .environment(AppSettings.shared)
        .environment(AppDependencies())
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .frame(width: 560, height: 600)
}

#Preview("English") {
    ServicesSettingsTab()
        .environment(AppSettings.shared)
        .environment(AppDependencies())
        .environment(\.locale, Locale(identifier: "en"))
        .frame(width: 560, height: 600)
}
