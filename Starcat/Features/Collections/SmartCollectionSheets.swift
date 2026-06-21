//
//  SmartCollectionSheets.swift
//  Starcat
//
//  用户智能集合辅助视图：规则摘要展示。
//
//  创建 / 编辑 / 重命名统一走 `SmartCollectionRuleEditorSheet`。
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
