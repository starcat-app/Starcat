//
//  HomePlaceholderView.swift
//  Starcat
//
//  登录后主界面占位（Week 3 会被三栏 HomeView 替换）。
//
//  暴露：
//  - 当前登录用户 login
//  - 本地已 star 计数
//  - 触发同步按钮 + 进度
//  - 登出按钮
//
//  Week 2 验收：登录成功 → 该界面 → 点击"同步" → 拉取 stars → 看到 count 增长。
//

import SwiftUI

struct HomePlaceholderView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(SyncManager.self) private var syncManager

    /// 本地已 star 数（异步刷新）。
    @State private var localCount: Int = 0

    var body: some View {
        VStack(spacing: 24) {
            header
            syncSection
            Divider().padding(.horizontal, 40)
            footer
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 380)
        .task(id: syncManager.state) {
            await refreshLocalCount()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if case .authenticated(let user) = authSession.state {
            VStack(spacing: 8) {
                avatarView(urlString: user.avatarUrl)
                Text("已登录")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("@\(user.login)")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
        }
    }

    /// GitHub 头像。
    /// 用 AsyncImage 直接拉 URL；Week 3 接入 Kingfisher 后再统一缓存策略。
    @ViewBuilder
    private func avatarView(urlString: String?) -> some View {
        let url = urlString.flatMap { URL(string: $0) }
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                // 网络失败回退占位
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            case .empty:
                // 加载中
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .overlay(Circle().stroke(.secondary.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                statBlock(title: "本地", value: "\(localCount)")
                statBlock(title: "状态", value: syncStateLabel)
            }

            if let progress = syncManager.progress {
                progressView(progress)
            }

            HStack(spacing: 12) {
                Button {
                    if case .authenticated(let user) = authSession.state {
                        syncManager.performFullSync(userID: user.id)
                    }
                } label: {
                    Label("同步 Stars", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(syncManager.isSyncing)

                if syncManager.isSyncing {
                    Button("取消") { syncManager.cancel() }
                        .controlSize(.large)
                }
            }
        }
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 120)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func progressView(_ progress: SyncProgress) -> some View {
        VStack(spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Text("第 \(progress.currentPage) 页，已同步 \(progress.current)\(progress.total.map { " / \($0)" } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 320)
    }

    private var syncStateLabel: String {
        switch syncManager.state {
        case .idle: return "空闲"
        case .syncing: return "同步中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .rateLimited: return "限流中"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if case .failed(let msg) = syncManager.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("退出登录", role: .destructive) {
                authSession.signOut()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Data

    private func refreshLocalCount() async {
        // 从 DatabaseManager 单例临时查；Week 3 抽到 ViewModel
        let repo = RepoRepository(database: DatabaseManager.shared)
        if let count = try? await repo.starredCount() {
            self.localCount = count
        }
    }
}
