//
//  CollapsibleSearchBar.swift
//  Starcat
//
//  自定义可展开收起的搜索框。
//
//  设计约束：
//  - 默认只占一个 toolbar 图标位，展开后向左变成稳定输入框。
//  - 有搜索词时失焦不自动清空，避免用户查看结果时丢失当前搜索状态。
//  - 当前只接入 keyword / FTS5 搜索，AI / Pro 状态仅预留视觉参数。
//

import SwiftUI

struct CollapsibleSearchBar: View {
    @Binding var text: String
    var showsAIAffordance = false
    var isAIModeActive = false

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var pendingCollapseTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let collapsedWidth: CGFloat = 30
    private let expandedWidth: CGFloat = 280
    private let searchHeight: CGFloat = 30
    private let cornerRadius: CGFloat = 10
    private let animation: Animation = .easeOut(duration: 0.22)

    private var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasQuery: Bool {
        !normalizedText.isEmpty
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedSearchField
            } else {
                collapsedSearchButton
            }
        }
        .frame(width: isExpanded ? expandedWidth : collapsedWidth, height: searchHeight)
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? cornerRadius : collapsedWidth / 2, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : animation, value: isExpanded)
        .onChange(of: isFocused) { _, newValue in
            guard !newValue else {
                pendingCollapseTask?.cancel()
                return
            }

            if isExpanded && !hasQuery {
                scheduleCollapseIfEmpty()
            }
        }
        .onChange(of: text) { _, newValue in
            // 搜索词可能来自外部状态恢复；有 query 时必须保持展开，才能让用户看见当前过滤条件。
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isExpanded {
                setExpanded(true)
            }
        }
        .onAppear {
            isExpanded = hasQuery
        }
    }

    private var collapsedSearchButton: some View {
        Button {
            openSearch()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                .frame(width: collapsedWidth, height: searchHeight)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: collapsedWidth / 2, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("search.hint")
    }

    private var expandedSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: isAIModeActive ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(leadingIconColor)
                .frame(width: 18, height: 18)

            TextField("search.repoPlaceholder", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(maxWidth: .infinity)
                .onExitCommand {
                    handleExitCommand()
                }

            if showsAIAffordance && !hasQuery {
                Text("AI")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.purple.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.purple.opacity(0.10))
                    }
            }

            Button {
                handleTrailingButtonTap()
            } label: {
                Image(systemName: hasQuery ? "xmark.circle.fill" : "xmark")
                    .font(.system(size: hasQuery ? 14 : 12, weight: .medium))
                    .foregroundStyle(hasQuery ? Color.secondary.opacity(0.75) : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(trailingButtonHelp)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isFocused || hasQuery ? 0.96 : 0.86))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
        }
        .shadow(color: shadowColor, radius: isFocused ? 5 : 0, x: 0, y: isFocused ? 1 : 0)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var leadingIconColor: Color {
        if isAIModeActive {
            return .purple
        }
        if isFocused || hasQuery {
            return .accentColor
        }
        return .secondary
    }

    private var borderColor: Color {
        if isAIModeActive {
            return Color.purple.opacity(isFocused ? 0.70 : 0.45)
        }
        if isFocused {
            return Color.accentColor.opacity(0.42)
        }
        if hasQuery {
            return Color.accentColor.opacity(0.24)
        }
        return Color.primary.opacity(isHovered ? 0.16 : 0.10)
    }

    private var shadowColor: Color {
        if isAIModeActive {
            return Color.purple.opacity(0.16)
        }
        return Color.accentColor.opacity(0.10)
    }

    private var trailingButtonHelp: LocalizedStringKey {
        hasQuery ? "search.clear" : "search.close"
    }

    private func openSearch() {
        pendingCollapseTask?.cancel()
        setExpanded(true)
        focusSearchField()
    }

    private func closeSearch() {
        pendingCollapseTask?.cancel()
        text = ""
        isFocused = false
        setExpanded(false)
    }

    private func clearSearch() {
        text = ""
        focusSearchField()
    }

    private func handleExitCommand() {
        if hasQuery {
            clearSearch()
        } else {
            closeSearch()
        }
    }

    private func handleTrailingButtonTap() {
        if hasQuery {
            clearSearch()
        } else {
            closeSearch()
        }
    }

    private func focusSearchField() {
        Task { @MainActor in
            await Task.yield()
            isFocused = true
        }
    }

    private func scheduleCollapseIfEmpty() {
        pendingCollapseTask?.cancel()

        // 失焦后延迟收起，给 toolbar 按钮点击和系统焦点切换留一个缓冲；
        // 否则用户刚点 clear / close 时会看到搜索栏闪动。
        pendingCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, !isFocused, !hasQuery else { return }
            setExpanded(false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if reduceMotion {
            isExpanded = expanded
        } else {
            withAnimation(animation) {
                isExpanded = expanded
            }
        }
    }
}
