//
//  RepoSkillScanNotice.swift
//  Starcat
//
//  扫描诊断按需放入 Popover，避免挤占 Skill 正文；只消费扫描快照，不触发额外探测。
//

import SwiftUI

/// 观察边界留在顶部入口，诊断列表只在用户展开时构建。
struct RepoSkillScanNotice: View {
    let session: RepoSkillSession

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @State private var isPresented = false

    var body: some View {
        if let scan = session.scan, !scan.complete,
           !session.isLoading || !scan.diagnostics.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("repo.skills.scan.details")
                    if !scan.diagnostics.isEmpty {
                        Text(scan.diagnostics.count, format: .number.locale(locale))
                            .monospacedDigit()
                    }
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("repo.skills.scan.incomplete")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                details(scan)
                    .appLocaleEnvironment()
            }
        }
    }

    /// Popover 跟随当前快照更新；重新检测仍复用会话的取消、账号与安装门控。
    private func details(_ scan: RepoSkillScan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("repo.skills.scan.details")
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                Spacer()
                SheetCloseButton { isPresented = false }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: String(
                    format: String.l10n("repo.skills.scan.recognizedFormat"),
                    Int64(scan.skills.count)
                ))
                if let checked = scan.manifestChecked, let total = scan.manifestTotal {
                    Text(verbatim: String(
                        format: String.l10n("repo.skills.scan.progress"), checked, total
                    ))
                    .foregroundStyle(.secondary)
                }
                Text("repo.skills.scan.incompleteHint")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !scan.diagnostics.isEmpty {
                Divider()
                Text("repo.skills.scan.issues")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                // 短列表用自然高度；超出上限才滚动，两种布局都为系统滚动条留出尾部空间。
                ViewThatFits(in: .vertical) {
                    diagnosticRows(scan.diagnostics)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        diagnosticRows(scan.diagnostics)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: 280)
            }
            Divider()
            HStack {
                Spacer()
                Button("repo.skills.scan.refresh") {
                    isPresented = false
                    Task { await session.load(force: true) }
                }
                .buttonStyle(.bordered)
                .disabled(session.isLoading || session.isInstalling)
            }
        }
        .font(interfaceScale.font(.caption))
        .foregroundStyle(.primary)
        .padding(16)
        .frame(width: 440, alignment: .leading)
    }

    /// 只拆分扫描器明确生成的 manifest 分隔符，普通网络诊断保留原文。
    private func diagnosticRows(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(messages.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    let message = messages[index]
                    if let separator = message.range(of: "SKILL.md: ") {
                        Text(verbatim: String(message[..<separator.upperBound].dropLast(2)))
                            .fontWeight(.medium)
                        Text(verbatim: String(message[separator.upperBound...]))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: message)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(.trailing, 16)
    }
}
