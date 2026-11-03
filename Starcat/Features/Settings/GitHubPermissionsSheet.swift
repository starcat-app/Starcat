//
//  GitHubPermissionsSheet.swift
//  Starcat
//
//  GitHub 权限只读说明：沿用登录流程的 scope 常量与已有描述，不查询令牌、不触发重新授权。
//  单列内容由 SwiftUI 自动 sheet 承载，高度随译文自然增长，不引入固定工作区窗口。
//

import SwiftUI

/// 展示当前账户，以及本版本在 GitHub 登录时请求的权限和组织授权限制。
/// scope 清单不是当前令牌已授予权限的核验结果，因此始终配合原有“登录时申请”说明。
struct GitHubPermissionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accountLogin: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("settings.privacy.github.title", systemImage: "checkmark.shield")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                SheetCloseButton { dismiss() }
            }

            Divider()

            HStack(spacing: 16) {
                Text("settings.privacy.github.account.title")

                Spacer(minLength: 0)

                if let accountLogin {
                    Text(verbatim: accountLogin)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(accountLogin)
                } else {
                    Text("settings.privacy.github.account.signedOut")
                        .foregroundStyle(.secondary)
                }
            }

            Text("settings.general.oauthScopes.summary")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                // 直接读取登录流程的单一真源，新增 scope 后说明列表也会同步呈现。
                ForEach(AppConstants.githubOAuthScopes, id: \.self) { scope in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: scope)
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                        Text(descriptionKey(for: scope))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)

                    if scope != AppConstants.githubOAuthScopes.last {
                        Divider()
                    }
                }
            }

            Text("settings.general.oauthScopes.organizationHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 只迁移原权限说明映射，未知 scope 继续显示既有通用说明，避免在 UI 里复制授权配置。
    private func descriptionKey(for scope: String) -> LocalizedStringKey {
        switch scope {
        case "read:user":
            "settings.general.oauthScopes.readUser"
        case "public_repo":
            "settings.general.oauthScopes.publicRepo"
        case "user":
            "settings.general.oauthScopes.user"
        case "notifications":
            "settings.general.oauthScopes.notifications"
        default:
            "settings.general.oauthScopes.unknown"
        }
    }
}
