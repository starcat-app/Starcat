//
//  LabsSettingsView.swift
//  Starcat
//
//  实验功能设置：引擎选择与对应配置同卡，业务使用范围独立展示。
//  Jev 草稿由页面持有，切换 Laya 不丢失输入；测试与凭据规则由
//  JevConnectionSettingsModel 管理，不改变业务调用的引擎选择与写入边界。
//

import SwiftUI

/// 使用原生 grouped Form 落实实验功能原型，保留现有设置绑定和模型生命周期。
struct LabsSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var jevConnection: JevConnectionSettingsModel?
    @State private var layaManager = LayaDecisionModelManager.shared
    @State private var layaTestState: LayaTestState = .idle
    @State private var showsDeleteLayaConfirmation = false

    private enum LayaTestState: Equatable {
        case idle
        case testing
        case succeeded(elapsedMilliseconds: Int, noul: Double)
        case failed(String)
    }

    private enum ConnectionProbeError: LocalizedError {
        case missingAnswer

        var errorDescription: String? {
            String.l10n("settings.labs.typesafe.test.missingAnswer")
        }
    }

    var body: some View {
        Form {
            SettingsPageIntroduction(
                title: "settings.navigation.item.labs",
                systemImage: "flask",
                description: "settings.labs.layout.introduction",
                context: "settings.labs.intro"
            )
            decisionEngineSection
            scopeSection
        }
        .formStyle(.grouped)
        .task {
            // 实例不放在引擎条件分支里，切换配置面板不会重建 Jev 草稿。
            if jevConnection == nil { jevConnection = JevConnectionSettingsModel(settings: settings) }
            layaManager.refreshFromSharedStorage()
        }
        .onChange(of: openRouterProfileRevision) { _, _ in
            jevConnection?.refreshOpenRouterFallback()
        }
        .onDisappear { jevConnection?.invalidateTest() }
        .alert("settings.labs.layout.deleteTitle", isPresented: $showsDeleteLayaConfirmation) {
            Button("general.cancel", role: .cancel) {}
            Button("settings.localai.model.action.delete", role: .destructive) {
                layaTestState = .idle
                layaManager.delete()
            }
        } message: {
            Text("settings.labs.layout.deleteMessage")
        }
    }

    private var decisionEngineSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.decisionEngineEnabled) {
                explanation("settings.labs.decision.enable", hint: "settings.labs.layout.enableHelp")
            }
            .toggleStyle(.switch)
            if settings.decisionEngineEnabled {
                Picker("settings.labs.layout.currentEngine", selection: $settings.decisionEngineID) {
                    ForEach(DecisionEngineID.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                switch settings.decisionEngineID {
                case .jev:
                    if let jevConnection { JevConnectionSettingsView(model: jevConnection) }
                case .laya:
                    layaConfiguration
                }
            } else {
                Text("settings.labs.layout.disabledHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader("settings.labs.decision.section", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private var scopeSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle(isOn: $settings.decisionGroupingSuggestionsEnabled) {
                explanation("settings.labs.layout.grouping", hint: "settings.labs.layout.groupingHelp")
            }
            .help(Text("settings.labs.decision.grouping.description"))
            Toggle(isOn: $settings.decisionTagSuggestionsEnabled) {
                explanation("settings.labs.layout.tags", hint: "settings.labs.layout.tagsHelp")
            }
            .help(Text("settings.labs.decision.tags.pooled.description"))
        } header: {
            SettingsSectionHeader("settings.labs.layout.scope", systemImage: "slider.horizontal.3")
        }
        .toggleStyle(.switch)
        .disabled(!settings.decisionEngineEnabled)
    }

    /// 标题与开关按整体中心对齐，备注在同一个 label 中自然换行。
    private func explanation(_ title: LocalizedStringKey, hint: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 对应引擎的完整配置留在选择器下方，不再创建第二个独立分组。
    private var layaConfiguration: some View {
        let descriptor = LayaDecisionModelCatalog.multilingual
        return VStack(alignment: .leading, spacing: 16) {
            Label("settings.labs.laya.section", systemImage: "cpu")
                .font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 12) {
                    Text(descriptor.displayName).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: descriptor.estimatedDownloadSize, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: descriptor.source.repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("settings.labs.laya.model.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            // 状态/测试反馈与操作同行，长错误仅在左侧换行，不把按钮挤到下一行。
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    layaInstallStatus
                    layaTestFeedback
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                layaInstallAction
                    .fixedSize()
                    .disabled(layaTestState == .testing)
                Button {
                    testLayaModel()
                } label: {
                    Text("settings.labs.laya.test")
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(layaManager.installedDirectoryURL == nil || layaTestState == .testing)
            }
            Text("settings.labs.laya.localOnly.note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var layaInstallStatus: some View {
        switch layaManager.installState {
        case .idle:
            Label("settings.labs.laya.status.notInstalled", systemImage: "square.and.arrow.down")
                .foregroundStyle(.secondary)
        case .preparing:
            Label("settings.localai.model.status.preparing", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case let .downloading(progress, completedBytes, totalBytes, _):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text(
                    "\(ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)) / "
                        + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        case let .failed(message), let .loadFailed(message), let .deleteFailed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("settings.labs.laya.status.loading")
                    .foregroundStyle(.secondary)
            }
        case .deleting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("settings.labs.laya.status.deleting")
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Label {
                Text("settings.labs.laya.status.ready")
                    .foregroundStyle(.secondary)
            } icon: {
                // 绿色只表达模型已经安装成功；状态文字继续保持设置页的次要层级。
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var layaInstallAction: some View {
        switch layaManager.installState {
        case .idle, .failed:
            Button("settings.labs.laya.install") {
                layaTestState = .idle
                layaManager.install()
            }
            .buttonStyle(.bordered)
        case .preparing, .downloading:
            Button("settings.localai.model.action.pause") {
                layaManager.pause()
            }
            .buttonStyle(.bordered)
        case .loadFailed:
            Button("settings.localai.model.action.retryLoad") {
                layaManager.retryLoad()
            }
            .buttonStyle(.bordered)
        case .installed, .deleteFailed:
            Button("settings.localai.model.action.delete", role: .destructive) {
                showsDeleteLayaConfirmation = true
            }
            .buttonStyle(.bordered)
        case .loading, .deleting:
            EmptyView()
        }
    }

    @ViewBuilder
    private var layaTestFeedback: some View {
        switch layaTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("settings.services.summary.checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .succeeded(milliseconds, noul):
            Label {
                Text(verbatim: String(
                    format: String.l10n("settings.labs.laya.test.successFormat"),
                    NSNumber(value: milliseconds),
                    String(format: "%.2f", noul)
                ))
                .foregroundStyle(.secondary)
            } icon: {
                // 测试通过与安装完成使用同一成功色，避免灰色勾误读为未确认状态。
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// 只监听会改变备用凭据资格的字段，避免比较整份模型列表。
    private var openRouterProfileRevision: [String] {
        settings.aiProviderProfiles.filter { $0.provider == .openRouter }.map {
            [$0.id, $0.displayName, String($0.isEnabled), String($0.lastTestStatus.isSuccess), $0.lastTestedAt ?? ""]
                .joined(separator: "|")
        }
    }

    /// 直接走与业务相同的 Laya 引擎抽象；测试成功代表安装清单、tokenizer、权重加载
    /// 和一次真实 batch forward 都可用，不以“文件存在”冒充 runtime 验证。
    private func testLayaModel() {
        guard layaManager.installedDirectoryURL != nil else { return }
        layaTestState = .testing
        Task {
            do {
                let engine = LayaDecisionEngine(modelManager: layaManager)
                let clock = ContinuousClock()
                let startedAt = clock.now
                let response = try await engine.evaluate(DecisionEvaluationRequest(
                    state: .text("Starcat is a native macOS application for managing GitHub stars."),
                    questions: [
                        "demo": DecisionNoulQuestion(
                            instructions: "Does this text describe a software product?",
                            criteria: nil
                        )
                    ],
                    operation: .connectionTest
                ))
                let elapsed = startedAt.duration(to: clock.now)
                let milliseconds = Int(elapsed.components.seconds) * 1_000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                guard let noul = response.answers["demo"]?.probability else {
                    throw ConnectionProbeError.missingAnswer
                }
                layaTestState = .succeeded(
                    elapsedMilliseconds: milliseconds,
                    noul: noul
                )
            } catch is CancellationError {
                layaTestState = .idle
            } catch {
                layaTestState = .failed(error.localizedDescription)
            }
        }
    }
}
