//
//  GeneralSettingsView.swift
//  Starcat
//
//  主设置的通用页：说明用途、按使用场景组织表单，直接绑定现有偏好。
//  页面只负责呈现，不新增配置副本，不改变即时保存、渠道门控与重置入口。
//

import AppKit
import SwiftUI

/// 独立承载通用表单，避免后续设置页调整继续膨胀主导航的视图与状态。
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var localeStore = LocaleStore.shared
    @State private var isAdvancedExpanded = false
    /// 捕获打开确认时的账号；切换账号后不允许将旧确认应用到新账号。
    @State private var listPreferencesResetLogin: String?
    @State private var showsListPreferencesReset = false
    @State private var listPreferencesResetToast: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            introductionSection
            appearanceSection
            macOSIntegrationSection

            // 感兴趣语言是长期候选池，保持在 macOS 集成之后，不与显示语言混排。
            InterestedLanguagesSettingsSection(languages: $settings.interestedLanguages)
            ExploreCatalogSettingsSection()

            if DistributionChannel.current.isDirect {
                directUpdateSection
            }

            advancedSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsListPreferencesReset) {
            ListPreferencesResetSheet(onConfirm: confirmListPreferencesReset)
                .appLocaleEnvironment()
        }
        .onChange(of: dependencies.authSession.state.user?.login) { _, _ in
            showsListPreferencesReset = false
            listPreferencesResetLogin = nil
        }
        .toast(message: $listPreferencesResetToast, icon: "arrow.counterclockwise", bottomPadding: 24)
    }

    /// 原生 grouped Section 本身提供卡片表面；这里不再嵌套自绘背景或固定高度。
    private var introductionSection: some View {
        Section {
            HStack(spacing: 16) {
                // 分类说明卡片按设计使用蓝色齿轮标识身份，普通 Section 图标仍沿用原有样式。
                Image(systemName: "gearshape.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.general.title")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("settings.general.introduction.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.general.introduction.description"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 外观与语言仅显示标题和控件，避免备注挤占分段选择器的布局空间。
    private var appearanceSection: some View {
        @Bindable var settings = settings

        return Section {
            centeredPreferenceRow(
                "settings.general.appearanceMode",
                description: "settings.general.appearanceMode.description",
                showsDescription: false
            ) {
                Picker("settings.general.appearanceMode", selection: appearanceSelection) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            centeredPreferenceRow(
                "settings.general.interfaceScale",
                description: "settings.general.interfaceScale.description",
                showsDescription: false
            ) {
                Picker("settings.general.interfaceScale", selection: $settings.interfaceScale) {
                    ForEach(InterfaceScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
            }

            languagePreferenceRow

            // 减少动画影响使用舒适度，保持常驻；这里只合并呈现，不改变系统偏好的叠加逻辑。
            preferenceToggle(
                "settings.general.disableAnimations.title",
                description: "settings.general.disableAnimations.help",
                showsDescription: false,
                isOn: $settings.disableAnimations
            )
        } header: {
            SettingsSectionHeader("settings.general.appearanceAndLanguage.title", systemImage: "paintbrush.fill")
        }
    }

    /// 保留主题切换的既有动画；系统或应用要求减少动态效果时立即生效。
    private var appearanceSelection: Binding<AppearanceMode> {
        Binding(
            get: { settings.appearanceMode },
            set: { newValue in
                if reduceMotion {
                    settings.appearanceMode = newValue
                } else {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        settings.appearanceMode = newValue
                    }
                }
            }
        )
    }

    /// 语言仍使用母语名称与 LocaleStore；不复制选择状态或改变菜单重启边界。
    private var languagePreferenceRow: some View {
        @Bindable var localeStore = localeStore

        return centeredPreferenceRow(
            "settings.general.language.label",
            description: "settings.general.language.description",
            showsDescription: false
        ) {
            Picker(selection: $localeStore.selection) {
                ForEach(AppLocale.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                Text("settings.general.language.label")
            }
            .pickerStyle(.menu)
        }
    }

    private var detailBehaviorRows: some View {
        @Bindable var settings = settings

        return Group {
            preferenceToggle(
                "settings.general.openFirstDetailOnCategoryChange.title",
                description: "settings.general.openFirstDetailOnCategoryChange.help",
                showsDescription: false,
                isOn: $settings.openFirstDetailOnCategoryChange
            )
            Divider()

            preferenceToggle(
                "settings.general.openRepositoryMarkdownInApp.title",
                description: "settings.general.openRepositoryMarkdownInApp.help",
                showsDescription: false,
                isOn: $settings.openRepositoryMarkdownInApp
            )
            Divider()

            preferenceToggle(
                "settings.activity.issueEvents.title",
                description: "settings.activity.issueEvents.help",
                showsDescription: false,
                isOn: $settings.githubIssueEventTimelineEnabled
            )
        }
    }

    private var macOSIntegrationSection: some View {
        @Bindable var settings = settings

        return Section {
            preferenceToggle(
                "settings.general.hideDockIcon.title",
                description: "settings.general.hideDockIcon.help",
                showsDescription: false,
                isOn: $settings.hideDockIcon
            )
            preferenceToggle(
                "settings.general.spotlightSearch.label",
                description: "settings.general.spotlightSearch.summary",
                showsDescription: false,
                isOn: $settings.spotlightSearchEnabled
            )

            if DistributionChannel.current.isDirect {
                ScreensaverSettingsSection()
            }
        } header: {
            SettingsSectionHeader("settings.general.macOSIntegration", systemImage: "macwindow.on.rectangle")
        }
    }

    /// 低频偏好只折叠呈现，展开后仍是原生表单行，避免多层卡片与配置副本。
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                // 展开内容位于自定义折叠容器内，需显式补齐标题及设置项之间的分割线。
                Divider()

                Text("settings.general.detailBehavior")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                detailBehaviorRows

                Divider()

                Text("settings.general.advanced.effects.title")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                contributionStyleRow

                Divider()

                Text("settings.general.reset")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                preferenceResetRows
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(SettingsIconMetrics.smallGlyph)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text("settings.general.advanced.title")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(Text("settings.general.advanced.title"))
                    }
                    Text("settings.general.advanced.summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(Text("settings.general.advanced.summary"))
                        // 摘要跳过 20pt 图标列及 6pt 间距，与标题文字对齐。
                        .padding(.leading, 26)
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.general.advanced.title")
            ))
        }
    }

    private var contributionStyleRow: some View {
        @Bindable var settings = settings

        return centeredPreferenceRow(
            "settings.snakeStyle.title",
            description: "settings.snakeStyle.description",
            showsDescription: false
        ) {
            Picker(selection: $settings.snakeStyle) {
                ForEach(SnakeStyle.allCases) { style in
                    Label(LocalizedStringKey(style.displayNameKey), systemImage: style.systemImage)
                        .tag(style)
                }
            } label: {
                Text("settings.snakeStyle.title")
            }
            .pickerStyle(.menu)
        }
    }

    /// 所有说明跟随对应开关，控件按整个文本块居中；不增加新的设置或表单草稿。
    private func preferenceToggle(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        showsDescription: Bool = true,
        isOn: Binding<Bool>
    ) -> some View {
        centeredPreferenceRow(title, description: description, showsDescription: showsDescription, onLabelActivate: {
            isOn.wrappedValue.toggle()
        }) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                // 隐藏内置标签后保留开关的原生尺寸，避免在 Form 内被拉伸。
                .fixedSize()
        }
    }

    /// 备注属于左侧标签块，不能放在整行下方；显式居中也避免首行基线将控件顶到上方。
    private func centeredPreferenceRow<Control: View>(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        showsDescription: Bool = true,
        onLabelActivate: (() -> Void)? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(Text(title))
            // 隐藏可见备注时仍保留读屏提示，其余设置行继续显示原有说明。
            if showsDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        return HStack(alignment: .center, spacing: 12) {
            if let onLabelActivate {
                // 保留点击开关原标签即可切换的行为；键盘和读屏只聚焦右侧原生开关，避免双入口。
                Button(action: onLabelActivate) {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focusable(false)
                .accessibilityHidden(true)
            } else {
                label
            }

            Spacer(minLength: 12)

            control()
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(description))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sparkle 配置仅在 Direct 页挂载，继续使用现有控制器与可用性判定。
    private var directUpdateSection: some View {
        let updateController = dependencies.directUpdateController

        return Section {
            Toggle("settings.pro.direct.updates.autoCheck", isOn: Binding(
                get: { updateController.automaticallyChecksForUpdates },
                set: { updateController.automaticallyChecksForUpdates = $0 }
            ))
            .disabled(!updateController.isConfigured)

            // 「更新通道」Picker 收敛为单个开关：用户心智是「愿不愿意先收预览版」，
            // 不需要在两条轨道间做选择。后端双 feed 结构不变——开即 development
            // appcast（内含正式条目），关即正式 appcast；偏好 key 也不变，存量
            // 「预览」用户天然映射为开关打开。切换仍走 selectUpdateChannel，保留
            // 「立即检查一次」行为；关开关不会降级，要等下一个构建号更高的正式版。
            // 两个 l10n key 暂未入 catalog（国际化批量任务冻结期，禁止改 xcstrings），
            // 先用 defaultValue 兜底，key 补录后自动接管。
            Toggle(isOn: Binding(
                get: { updateController.updateChannel == .development },
                set: { includePreview in
                    updateController.selectUpdateChannel(includePreview ? .development : .stable)
                }
            )) {
                Text(String.l10n(
                    "settings.pro.direct.updates.includePreview",
                    defaultValue: "Include preview updates"
                ))
            }
            .disabled(!updateController.isConfigured)

            if updateController.updateChannel == .development {
                Text(String.l10n(
                    "settings.pro.direct.updates.includePreview.help",
                    defaultValue: "Preview updates may include unfinished or unstable features. Turning this off will not downgrade the installed version."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("settings.pro.direct.updates.autoDownload", isOn: Binding(
                get: { updateController.automaticallyDownloadsUpdates },
                set: { updateController.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updateController.isConfigured || !updateController.automaticallyChecksForUpdates)

            HStack {
                Spacer()
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Text("settings.pro.direct.updates.check")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!updateController.canCheckForUpdates)
            }
        } header: {
            SettingsSectionHeader("settings.pro.direct.updates.section", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            // 已配置时不再展示自动下载说明；仅保留未配置时解释更新检查为何禁用的提示。
            if !updateController.isConfigured {
                Text("settings.pro.direct.updates.notConfigured")
            }
        }
    }

    /// 左侧说明重置对象，右侧统一图标入口；这些动作仍由既有确认或引导流程完成。
    private var preferenceResetRows: some View {
        Group {
            LabeledContent {
                ResetIconButton(
                    help: Text("settings.listPreferences.reset.title"),
                    showsSuccessFeedback: false,
                    action: resetListPreferences
                )
                .disabled(!dependencies.authSession.state.isAuthenticated)
                .help(Text(LocalizedStringKey(dependencies.authSession.state.isAuthenticated
                                             ? "settings.listPreferences.reset.title"
                                             : "settings.listPreferences.reset.disabled")))
            } label: {
                Text("settings.listPreferences.reset.title")
                    .lineLimit(1)
                    .help(Text("settings.listPreferences.reset.title"))
            }

            Divider()

            LabeledContent {
                ResetIconButton(
                    help: Text("settings.general.resetOnboarding.label"),
                    showsSuccessFeedback: false,
                    action: replayOnboarding
                )
                .disabled(!FirstRunOnboardingPreferences.canReplayManually)
            } label: {
                Text("settings.general.resetOnboarding.label")
                    .lineLimit(1)
                    .help(Text("settings.general.resetOnboarding.label"))
            }
        }
    }

    /// 确认由发起操作的设置窗口承载，不能把请求转发给主窗口弹窗。
    private func resetListPreferences() {
        guard let login = dependencies.authSession.state.user?.login else { return }
        listPreferencesResetLogin = login
        showsListPreferencesReset = true
    }

    /// 主窗口关闭时也可重置；主窗口在收到完成通知后只同步列表内存状态。
    private func confirmListPreferencesReset() {
        showsListPreferencesReset = false
        guard let login = listPreferencesResetLogin,
              login == dependencies.authSession.state.user?.login,
              settings.resetListViewPreferences(login: login) else { return }
        listPreferencesResetLogin = nil
        listPreferencesResetToast = String.l10n("settings.listPreferences.reset.toast")
        dependencies.telemetryManager.track(.listPreferencesReset)
    }

    /// 关闭设置后复用原引导流程，不在通用页重新创建一套引导状态。
    private func replayOnboarding() {
        guard FirstRunOnboardingPreferences.canReplayManually else { return }
        NSApp.keyWindow?.close()
        FirstRunOnboardingPreferences.requestManualReplay()
    }
}
