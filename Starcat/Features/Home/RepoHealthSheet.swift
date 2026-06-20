//
//  RepoHealthSheet.swift
//  Starcat
//
//  Repo Health 详情 sheet。
//
//  设计约束：
//  - Sheet 只读 `RepoHealthStore` 的缓存快照；无缓存时触发非阻塞刷新。
//  - 第一版不在 UI 中展示 payload_json 里的英文证据句，避免未本地化文本直出。
//  - OpenSSF 作为 Security 维度的来源之一保留入口，用户需要细看安全检查时再打开
//    原 OpenSSF sheet。
//

import SwiftUI

struct RepoHealthSheet: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var showOpenSSFScoreSheet = false

    private var store: RepoHealthStore { dependencies.repoHealthStore }
    private var snapshot: RepoHealthSnapshot? { store.snapshot(for: repo.id) }
    private var payload: RepoHealthPayload? {
        guard let raw = snapshot?.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RepoHealthPayload.self, from: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 820,
               minHeight: 520, idealHeight: 580, maxHeight: 720)
        .task(id: repo.id) {
            await store.loadCachedSnapshots(for: [repo.id])
            if store.snapshot(for: repo.id) == nil {
                store.prefetchIfNeeded(repo: repo)
            }
        }
        .sheet(isPresented: $showOpenSSFScoreSheet) {
            OpenSSFScoreSheet(repo: repo)
                .appSheetRootEnvironment(dependencies)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("repoHealth.sheet.title")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(verbatim: repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.refresh(repo: repo, force: true) }
            } label: {
                Label("repoHealth.action.refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.isLoading(repoId: repo.id))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scoreSummary(snapshot)
                    dimensionGrid(snapshot)
                    metadataSection(snapshot)
                }
                .padding(16)
            }
        } else {
            loadingContent
        }
    }

    private func scoreSummary(_ snapshot: RepoHealthSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(healthTint(snapshot.overallScore).opacity(0.14))
                Circle()
                    .stroke(healthTint(snapshot.overallScore).opacity(0.42), lineWidth: 1)
                VStack(spacing: 0) {
                    Text(verbatim: "\(Int(snapshot.overallScore.rounded()))")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(verbatim: snapshot.grade)
                        .font(.headline)
                        .foregroundStyle(healthTint(snapshot.overallScore))
                }
            }
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 8) {
                Text("repoHealth.score.overall")
                    .font(.headline)
                Text(statusText(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let computed = snapshot.computedDate {
                    Text(String(format: String.l10n("repoHealth.computedAtFormat"), formattedDate(computed)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func dimensionGrid(_ snapshot: RepoHealthSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            dimensionCard(title: "repoHealth.dimension.maintenance", score: snapshot.maintenanceScore, systemImage: "wrench.and.screwdriver")
            dimensionCard(title: "repoHealth.dimension.popularity", score: snapshot.popularityScore, systemImage: "star.circle")
            dimensionCard(title: "repoHealth.dimension.quality", score: snapshot.qualityScore, systemImage: "checklist")
            dimensionCard(title: "repoHealth.dimension.security", score: snapshot.securityScore, systemImage: "checkmark.shield")
        }
    }

    private func dimensionCard(title: LocalizedStringKey, score: Double, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(healthTint(score))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ProgressView(value: score, total: 100)
                    .tint(healthTint(score))
            }
            Spacer()
            Text(verbatim: "\(Int(score.rounded()))")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metadataSection(_ snapshot: RepoHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("repoHealth.sources.title")
                .font(.headline)

            metadataRow(
                icon: "tag",
                title: "repoHealth.sources.latestRelease",
                value: payload?.latestReleaseTag ?? String.l10n("repoHealth.sources.missing")
            )
            metadataRow(
                icon: "checkmark.shield",
                title: "repoHealth.sources.openSSF",
                value: payload?.openSSFScore.map { String(format: "%.1f", $0) } ?? String.l10n("repoHealth.sources.missing")
            )

            Button {
                showOpenSSFScoreSheet = true
            } label: {
                Label("repoHealth.action.openOpenSSF", systemImage: "checkmark.shield")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metadataRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .font(.subheadline)
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("repoHealth.loading")
                .font(.headline)
            Text("repoHealth.loading.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func statusText(_ snapshot: RepoHealthSnapshot) -> String {
        switch snapshot.fetchStatus {
        case .success:
            return String.l10n("repoHealth.status.success")
        case .partial:
            return String.l10n("repoHealth.status.partial")
        case .failed:
            return String.l10n("repoHealth.status.failed")
        }
    }

    private func healthTint(_ score: Double) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .yellow }
        return .red
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

