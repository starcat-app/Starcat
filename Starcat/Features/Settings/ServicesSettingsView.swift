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
                .disabled(!hasCustomURL(for: service) && draft(for: service).isEmpty)
                .help(Text("settings.services.reset.help"))
            }

            // 校验失败 / 当前生效 / 测试结果 caption
            captionRow(for: service, validation: validation)

            // 测试连接按钮（独立行，左对齐）
            HStack {
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
            }
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
        var loaded: [String: String] = [:]
        for service in ThirdPartyService.allCases {
            loaded[service.id] = settings.customServiceURL(for: service) ?? ""
        }
        // 仅在尚无草稿时填充，避免覆盖正在编辑的内容（虽然 task 一般只跑一次）。
        if draftURLs.isEmpty {
            draftURLs = loaded
        }
    }

    /// 保存当前草稿。`validation` 必须是 `.valid` 或 `.empty`，调用方已检查 `canPersist`。
    private func save(service: ThirdPartyService, validation: ServiceURLValidation) async {
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
        // 保存后清掉旧的健康检查结果——URL 已变，旧结果与新 URL 无关，留着误导。
        healthResults[service.id] = nil
    }

    /// 重置某服务的 URL（清持久化 + actor 回 production）。同时清空草稿。
    private func reset(service: ThirdPartyService) async {
        savingServiceID = service.id
        defer { savingServiceID = nil }
        await dependencies.resetServiceURL(for: service)
        draftURLs[service.id] = ""
        healthResults[service.id] = nil
    }

    /// 测试连接。用当前**草稿**的 URL（如果合法），否则用"当前生效"URL（已保存的或默认）。
    /// 这样用户即使没点保存，也能先测一下新地址是否通。
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

        let outcome = await dependencies.serviceHealthChecker.check(service: service, baseURL: baseURL)
        healthResults[service.id] = outcome
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

    private func colorForOutcome(_ outcome: HealthCheckOutcome) -> Color {
        switch outcome {
        case .ok: return .green
        case .reachableButError: return .orange
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
