//
//  SmartCollectionSheets.swift
//  Starcat
//
//  用户智能集合 v2 UX：保存 / 更新规则 / 重命名 Sheet。
//
//  命中数预览在 Sheet 内部加载，避免写回 RepoListView @State 导致父视图高频
//  重绘 → sheet 闪动 / 窗口抖动（HomeViewModel 列表仍在后台刷新）。
//

import SwiftUI

// MARK: - 规则摘要视图

struct SmartCollectionRuleSummaryView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("smartCollections.rule.summaryTitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 命中数行（固定高度，避免 ProgressView 显隐撑高 sheet）

private struct SmartCollectionMatchCountRow: View {
    let matchCount: Int?
    let isLoadingCount: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .opacity(isLoadingCount ? 1 : 0)
                .frame(width: 16, height: 16)

            if let matchCount, !isLoadingCount {
                Text(String(format: String.l10n("smartCollections.rule.matchCountFormat"), locale: locale, matchCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 22, alignment: .leading)
    }
}

// MARK: - 保存

struct SaveSmartCollectionSheet: View {
    let rule: SmartCollectionRule
    let summaryContext: SmartCollectionRuleSummary.Context
    let defaultName: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: (String, SmartCollectionRule) -> Void

    @Environment(HomeViewModel.self) private var viewModel
    @State private var name: String = ""
    @State private var matchCount: Int?
    @State private var isLoadingCount = false

    private var summaryLines: [String] {
        SmartCollectionRuleSummary.lines(rule: rule, context: summaryContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("smartCollections.save.title", systemImage: "line.3.horizontal.decrease.circle")
                .font(.headline)

            SmartCollectionRuleSummaryView(lines: summaryLines)

            SmartCollectionMatchCountRow(matchCount: matchCount, isLoadingCount: isLoadingCount)

            TextField("smartCollections.save.name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    if name.isEmpty { name = defaultName }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("general.cancel") {
                    onCancel()
                }
                Button("smartCollections.save.confirm") {
                    onSave(name, rule)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            await loadMatchCount()
        }
    }

    private func loadMatchCount() async {
        isLoadingCount = true
        defer { isLoadingCount = false }
        matchCount = try? await viewModel.countRepos(matching: rule)
    }
}

// MARK: - 更新规则

struct UpdateSmartCollectionSheet: View {
    let rule: SmartCollectionRule
    let summaryContext: SmartCollectionRuleSummary.Context
    let collectionName: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: (SmartCollectionRule) -> Void

    @Environment(HomeViewModel.self) private var viewModel
    @State private var matchCount: Int?
    @State private var isLoadingCount = false

    private var summaryLines: [String] {
        SmartCollectionRuleSummary.lines(rule: rule, context: summaryContext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("smartCollections.update.title", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            Text(String(format: String.l10n("smartCollections.update.messageFormat"), collectionName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SmartCollectionRuleSummaryView(lines: summaryLines)

            SmartCollectionMatchCountRow(matchCount: matchCount, isLoadingCount: isLoadingCount)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("general.cancel") {
                    onCancel()
                }
                Button("smartCollections.update.confirm") {
                    onConfirm(rule)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            await loadMatchCount()
        }
    }

    private func loadMatchCount() async {
        isLoadingCount = true
        defer { isLoadingCount = false }
        matchCount = try? await viewModel.countRepos(matching: rule)
    }
}

// MARK: - 重命名

struct RenameSmartCollectionSheet: View {
    let currentName: String
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("smartCollections.rename.title", systemImage: "pencil")
                .font(.headline)

            TextField("smartCollections.save.name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    if name.isEmpty { name = currentName }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("general.cancel") {
                    onCancel()
                }
                Button("smartCollections.rename.confirm") {
                    onConfirm(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
