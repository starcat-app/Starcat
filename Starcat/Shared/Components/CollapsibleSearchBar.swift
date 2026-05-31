//
//  CollapsibleSearchBar.swift
//  Starcat
//
//  自定义可展开收起的搜索框，类似 macOS Finder。
//

import SwiftUI

struct CollapsibleSearchBar: View {
    @Binding var text: String

    @State private var isExpanded = false
    @FocusState private var isFocused: Bool

    private let collapsedWidth: CGFloat = 28
    private let expandedWidth: CGFloat = 220
    private let animation: Animation = .easeOut(duration: 0.24)

    var body: some View {
        HStack(spacing: 6) {
            if isExpanded {
                TextField("搜索仓库", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .onExitCommand {
                        closeSearch()
                    }
            }

            Button {
                if isExpanded {
                    closeSearch()
                } else {
                    openSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: collapsedWidth, height: collapsedWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("搜索")
        }
        .padding(.horizontal, isExpanded ? 8 : 0)
        .frame(width: isExpanded ? expandedWidth : collapsedWidth, height: collapsedWidth)
        .background {
            RoundedRectangle(cornerRadius: isExpanded ? 7 : collapsedWidth / 2, style: .continuous)
                // toolbar 本身已经有材质背景；搜索框不再额外填充一层底色，避免和其他按钮胶囊色不一致。
                .fill(.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: isExpanded ? 7 : collapsedWidth / 2, style: .continuous)
                        .stroke(isFocused ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.2),
                                lineWidth: isExpanded ? 1 : 0)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 7 : collapsedWidth / 2, style: .continuous))
        .animation(animation, value: isExpanded)
        .onChange(of: isFocused) { _, newValue in
            if !newValue && isExpanded {
                closeSearch()
            }
        }
        .onAppear {
            isExpanded = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func openSearch() {
        withAnimation(animation) {
            isExpanded = true
        }
        Task { @MainActor in
            await Task.yield()
            isFocused = true
        }
    }

    private func closeSearch() {
        withAnimation(animation) {
            isExpanded = false
            text = ""
            isFocused = false
        }
    }
}
