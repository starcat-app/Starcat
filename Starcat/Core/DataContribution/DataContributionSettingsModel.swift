//
//  DataContributionSettingsModel.swift
//  Starcat
//
//  Settings 页公开 Star 数据贡献开关的最小可观察状态。
//
//  产品约束：UI 只展示开关，不展示上传数量、时间、错误或重试状态。持久化失败时
//  静默恢复数据库真值，不能弹 alert、通知或把错误传播到其他设置项。
//

import Foundation

@MainActor
@Observable
final class DataContributionSettingsModel {
    private let coordinator: DataContributionCoordinator

    private(set) var isEnabled = false
    private(set) var accountID: Int64?

    init(coordinator: DataContributionCoordinator) {
        self.coordinator = coordinator
    }

    func reload(accountID: Int64?) async {
        self.accountID = accountID
        guard let accountID else {
            isEnabled = false
            return
        }
        do {
            let preferences = try await coordinator.preferences(accountID: accountID)
            guard self.accountID == accountID else { return }
            isEnabled = preferences.isEnabled
        } catch {
            guard self.accountID == accountID else { return }
            isEnabled = false
        }
    }

    func setEnabled(_ newValue: Bool, accountID: Int64) async {
        guard self.accountID == accountID else { return }
        isEnabled = newValue
        do {
            let preferences = try await coordinator.setEnabled(newValue, accountID: accountID)
            guard self.accountID == accountID else { return }
            isEnabled = preferences.isEnabled
        } catch {
            // 失败不打扰用户；重新读取本地真值，避免 Toggle 长期显示未落库的状态。
            await reload(accountID: accountID)
        }
    }
}
