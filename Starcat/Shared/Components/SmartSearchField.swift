//
//  SmartSearchField.swift
//  Starcat
//
//  可折叠的智能搜索框组件。
//
//  模块职责：
//  - 在一个 toolbar 组件内承载关键词搜索 / AI 语义搜索两种模式；
//  - 折叠态只占一个图标宽度，避免挤压 macOS toolbar；
//  - 展开态内嵌模式切换、输入框、清空按钮和 AI 向量索引刷新入口；
//  - AI 模式提供克制的彩色光晕，但仍保持桌面应用的原生工具栏比例。
//
//  关键约束：
//  - 搜索业务状态由调用方传入的 Binding 管理，组件不直接依赖 HomeViewModel；
//  - 所有 plain button 必须禁用 focus ring，遵守 Starcat 的 toolbar 视觉约束；
//  - Reduce Motion 开启时不做动态光晕，只保留静态渐变边框。
//

import SwiftUI

/// Starcat 主 toolbar 使用的智能搜索输入框。
///
/// 折叠与聚焦属于局部 UI 状态，因此留在组件内部；搜索词、搜索模式和索引状态来自
/// 调用方，保证业务逻辑仍集中在 `HomeViewModel` / `AppSettings`。
struct SmartSearchField: View {
    @Binding var text: String
    @Binding var mode: SmartSearchMode

    let isIndexing: Bool
    let onRefreshSemanticIndex: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded = false
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var isCollapsedIconFocused: Bool

    private let collapsedWidth: CGFloat = 42
    private let expandedWidth: CGFloat = 440
    private let height: CGFloat = 38

    private var isSemantic: Bool { mode == .semantic }

    /// 空输入但仍聚焦时保持展开；有输入时即便失焦也保持展开，避免用户看不见当前筛选条件。
    private var shouldExpand: Bool {
        isExpanded || isTextFieldFocused || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if shouldExpand {
                expandedField
            } else {
                collapsedButton
            }
        }
        .frame(width: shouldExpand ? expandedWidth : collapsedWidth, height: height)
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: shouldExpand)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: mode)
        .onChange(of: isTextFieldFocused) { _, focused in
            if focused {
                isExpanded = true
            } else {
                collapseIfPossible()
            }
        }
        .onChange(of: isCollapsedIconFocused) { _, focused in
            if focused {
                expandAndFocusInput()
            }
        }
        .onChange(of: mode) { _, _ in
            expandAndFocusInput()
        }
    }

    /// 折叠态只露出当前模式图标。
    ///
    /// 点击时不直接弹模式菜单，而是先展开搜索框；展开后左侧的图标 + chevron 再负责模式切换。
    /// 这样可以避免一次点击同时触发“展开”和“打开菜单”的歧义。
    private var collapsedButton: some View {
        Button {
            expandAndFocusInput()
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSemantic ? .purple : .secondary)
                .frame(width: collapsedWidth, height: height)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isCollapsedIconFocused)
        .help(mode == .semantic ? Text("search.semantic.placeholder") : Text("search.repoPlaceholder"))
        .background(searchBackground)
        .overlay(searchBorder)
        .overlay(aiGlow)
    }

    /// 展开态：模式菜单、输入框和右侧操作都收进同一个胶囊里。
    private var expandedField: some View {
        HStack(spacing: 8) {
            modeMenu

            TextField(promptKey, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .focused($isTextFieldFocused)
                .submitLabel(.search)

            if isSemantic {
                Divider()
                    .frame(height: 18)
                    .opacity(0.38)
                semanticRefreshButton
            }

            if !text.isEmpty {
                clearButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, text.isEmpty ? 10 : 7)
        .frame(height: height)
        .background(searchBackground)
        .overlay(searchBorder)
        .overlay(aiGlow)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            expandAndFocusInput()
        }
    }

    private var modeMenu: some View {
        Menu {
            Picker("search.mode.title", selection: $mode) {
                ForEach(SmartSearchMode.allCases) { option in
                    Label {
                        Text(option.displayName)
                    } icon: {
                        Image(systemName: option.systemImage)
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.72)
            }
            .foregroundStyle(isSemantic ? .purple : .secondary)
            .frame(width: 44, height: 26)
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .focusEffectDisabled()
        .help("search.mode.hint")
    }

    private var semanticRefreshButton: some View {
        Button {
            onRefreshSemanticIndex()
        } label: {
            Group {
                if isIndexing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isIndexing)
        .foregroundStyle(isIndexing ? Color.secondary : Color.green)
        .help(isIndexing ? Text("search.semantic.indexing") : Text("search.semantic.refreshIndex"))
    }

    private var clearButton: some View {
        Button {
            text = ""
            expandAndFocusInput()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("search.clear")
    }

    private var promptKey: LocalizedStringKey {
        isSemantic ? "search.semantic.placeholder" : "search.repoPlaceholder"
    }

    private var searchBackground: some View {
        Capsule(style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Capsule(style: .continuous)
                    .fill((isSemantic ? Color.purple : Color.primary).opacity(isSemantic ? 0.055 : 0.035))
            }
    }

    private var searchBorder: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                isSemantic ? Color.purple.opacity(0.36) : Color.secondary.opacity(0.22),
                lineWidth: 1
            )
    }

    @ViewBuilder
    private var aiGlow: some View {
        if isSemantic {
            SmartSearchAIGlow(isActive: isTextFieldFocused || !text.isEmpty || isIndexing)
                .allowsHitTesting(false)
        }
    }

    private func expandAndFocusInput() {
        isExpanded = true
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
    }

    private func collapseIfPossible() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if !isTextFieldFocused && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = false
            }
        }
    }
}

/// AI 语义搜索模式下的彩色光晕。
///
/// 光晕只作为状态提示，不承担布局边界；因此用 overlay 绘制在胶囊边缘，避免影响 toolbar
/// 高度。动态 hue rotation 只在未开启 Reduce Motion 时运行。
private struct SmartSearchAIGlow: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let gradient = AngularGradient(
        colors: [
            .cyan.opacity(0.72),
            .purple.opacity(0.78),
            .pink.opacity(0.72),
            .orange.opacity(0.58),
            .cyan.opacity(0.72)
        ],
        center: .center
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let hue = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 6) / 6 * 42

            Capsule(style: .continuous)
                .strokeBorder(gradient, lineWidth: isActive ? 1.45 : 1.05)
                .hueRotation(.degrees(hue))
                .shadow(color: .cyan.opacity(isActive ? 0.24 : 0.13), radius: isActive ? 7 : 4)
                .shadow(color: .pink.opacity(isActive ? 0.18 : 0.10), radius: isActive ? 9 : 5)
                .padding(1)
        }
    }
}
