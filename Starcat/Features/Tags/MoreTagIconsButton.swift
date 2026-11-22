//
//  MoreTagIconsButton.swift
//  Starcat
//
//  新建与编辑标签共用的本地图标库入口。选择结果写入表单草稿。
//

import SwiftUI

/// 打开素材选择器，并在入口旁预览当前所选素材。
struct MoreTagIconsButton: View {
    @Binding var selection: String?
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isPresented.toggle()
            } label: {
                Label("tagIcon.browser.more", systemImage: "square.grid.2x2")
                    .lineLimit(1)
            }
            .controlSize(.small)
            .help("tagIcon.browser.more")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                TagIconBrowser(selection: $selection)
                    .appLocaleEnvironment()
            }

            if let selection, let entry = TagIconCatalog.entry(for: selection) {
                TagIconView(identifier: selection, size: 16)
                    .foregroundStyle(.primary)
                    .help(Text(verbatim: entry.name))
                    .accessibilityRepresentation {
                        Text(verbatim: entry.name)
                    }
            }
        }
    }
}

/// 只在打开浮层时创建资源网格，图片由滚动容器按可见区域加载。
private struct TagIconBrowser: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedIconID: String?
    @State private var query = ""
    @State private var hoveredID: String?
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("tagManagement.icon")
                        .font(interfaceScale.font(.panelTitle))
                    Spacer()
                    SheetCloseButton { dismiss() }
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("tagIcon.browser.search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                }
            }
            .padding(12)

            Divider()

            results
        }
        .frame(width: 400, height: 350)
        .defaultFocus($isSearchFocused, true)
        .onExitCommand { dismiss() }
        .onChange(of: query) { scrollPosition.scrollTo(edge: .top) }
    }

    /// 搜索同时覆盖所有素材来源，按来源保留稳定的浏览顺序。
    @ViewBuilder
    private var results: some View {
        let groups = Dictionary(grouping: TagIconCatalog.matching(query), by: \.source)
        if groups.isEmpty {
            ContentUnavailableView("tagIcon.browser.noResults", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                    ForEach(TagIconCatalog.Source.allCases, id: \.self) { source in
                        if let entries = groups[source] {
                            Section {
                                ForEach(entries) { entry in
                                    iconButton(entry)
                                }
                            } header: {
                                Text(title(for: source))
                                    .font(interfaceScale.font(.captionStrong))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .scrollPosition($scrollPosition)
        }
    }

    private func title(for source: TagIconCatalog.Source) -> LocalizedStringKey {
        switch source {
        case .lucide: "Lucide"
        case .devicon: "Devicon"
        case .skillAgent: "skills.workspace.agents"
        case .aiProvider: "settings.ai.provider"
        }
    }

    /// 点选只更新原表单的草稿，因此创建、保存和取消沿用现有操作。
    private func iconButton(_ entry: TagIconCatalog.Entry) -> some View {
        let isSelected = selection == entry.id
        let isHovered = hoveredID == entry.id
        let isFocused = focusedIconID == entry.id
        return Button {
            selection = isSelected ? nil : entry.id
            dismiss()
        } label: {
            VStack(spacing: 4) {
                TagIconView(identifier: entry.id, size: 22)
                    .foregroundStyle(.primary)
                Text(verbatim: entry.name)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(5)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovered ? 0.10 : 0.05),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected || isFocused ? Color.accentColor : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedIconID, equals: entry.id)
        .onHover { hovering in
            if hovering {
                hoveredID = entry.id
            } else if hoveredID == entry.id {
                hoveredID = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(Text(verbatim: entry.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(Text(verbatim: entry.name))
    }
}
