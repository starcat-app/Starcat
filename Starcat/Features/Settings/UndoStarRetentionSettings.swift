//
//  UndoStarRetentionSettings.swift
//  Starcat
//
//  数据与存储页的 Undo Star 历史保留设置：天数草稿与永久保留共用原配置。
//  缩短保留期仍先确认，再调用原清理调度器；输入过程中不写配置或删除历史。
//

import SwiftUI

/// 用明确的天数输入替代分段滑杆，保留永久值 -1 和原有清理确认流程。
struct UndoStarRetentionSettings: View {
    @Binding var retentionDays: Int
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @State private var retainedCount: Int?
    @State private var daysDraft = ""
    @State private var lastFiniteDays = 7
    @State private var pendingDays = 7
    @State private var showShortenConfirm = false
    @State private var showDeleteNowConfirm = false
    @FocusState private var isDaysFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.storage.layout.retention.title")
                    Text("settings.storage.layout.retention.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                TextField("", text: $daysDraft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .accessibilityLabel(Text("settings.storage.layout.retention.title"))
                    .focused($isDaysFocused)
                    .disabled(retentionDays <= 0)
                    .onChange(of: daysDraft) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(9))
                        if digits != value { daysDraft = digits }
                    }
                    .onSubmit { commitDays() }
                    .onChange(of: isDaysFocused) { _, focused in
                        if !focused { commitDays() }
                    }
            }

            Divider()

            Toggle("settings.storage.layout.retention.forever", isOn: Binding(
                get: { retentionDays <= 0 },
                set: { forever in
                    requestRetention(forever ? -1 : lastFiniteDays)
                }
            ))
            .toggleStyle(.switch)

            Divider()

            HStack {
                if let retainedCount {
                    Text(verbatim: String(
                        format: String.l10n("settings.storage.refinement.undoStarCount"),
                        locale: locale,
                        retainedCount
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    showDeleteNowConfirm = true
                } label: {
                    Text("settings.undoStar.deleteNow")
                }
                .disabled(dependencies.undoStarCleanupScheduler.isCleaning)
                .help("settings.undoStar.deleteNow.help")
            }
        }
        .onAppear { synchronizeDraft() }
        .task(id: authSession.state.user?.id) { await refreshRetainedCount() }
        .onReceive(NotificationCenter.default.publisher(for: .undoStarHistoryDidChange)) { _ in
            Task { await refreshRetainedCount() }
        }
        .onChange(of: dependencies.undoStarCleanupScheduler.lastCleanupAt) { _, _ in
            Task { await refreshRetainedCount() }
        }
        .onChange(of: retentionDays) { _, _ in synchronizeDraft() }
        .alert("settings.undoStar.shortenTitle", isPresented: $showShortenConfirm) {
            Button("settings.undoStar.shortenCancel", role: .cancel) { synchronizeDraft() }
            Button("settings.undoStar.shortenDelete", role: .destructive) {
                retentionDays = pendingDays
                synchronizeDraft()
                Task { await dependencies.undoStarCleanupScheduler.cleanupNow() }
            }
        } message: {
            Text("settings.undoStar.shortenMessage")
        }
        .alert("settings.undoStar.deleteNowTitle", isPresented: $showDeleteNowConfirm) {
            Button("settings.undoStar.deleteNowCancel", role: .cancel) {}
            Button("settings.undoStar.deleteNowConfirm", role: .destructive) {
                Task { await dependencies.undoStarCleanupScheduler.cleanupNow() }
            }
        } message: {
            Text("settings.undoStar.deleteNowMessage")
        }
    }

    /// 账号切换后不显示旧账号数字；清理、重新 Star 与取消 Star 后都重新读取真实历史数。
    private func refreshRetainedCount() async {
        let userID = authSession.state.user?.id
        retainedCount = nil
        guard userID != nil else { return }
        let count = try? await dependencies.undoStarHistoryRepository.count()
        guard authSession.state.user?.id == userID else { return }
        retainedCount = count
    }

    /// 提交时才钳制范围；非法或空草稿恢复原值，避免编辑中途打断全选替换。
    private func commitDays() {
        guard retentionDays > 0, !showShortenConfirm else { return }
        guard let days = Int(daysDraft) else {
            synchronizeDraft()
            return
        }
        requestRetention(min(365, max(1, days)))
    }

    /// 永久保留的排序高于任何天数；缩短时先确认，取消不会改变现有配置。
    private func requestRetention(_ days: Int) {
        let oldRank = retentionDays <= 0 ? Int.max : retentionDays
        let newRank = days <= 0 ? Int.max : days
        if newRank < oldRank {
            pendingDays = days
            showShortenConfirm = true
        } else {
            retentionDays = days
            synchronizeDraft()
        }
    }

    /// 切换永久保留时保留上一份有限天数草稿；持久化仍只使用原来的 Int 配置。
    private func synchronizeDraft() {
        if retentionDays > 0 {
            lastFiniteDays = min(365, max(1, retentionDays))
        }
        daysDraft = String(lastFiniteDays)
    }
}
