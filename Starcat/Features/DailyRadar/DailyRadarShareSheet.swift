//
//  DailyRadarShareSheet.swift
//  Starcat
//
//  展示实际上传头图及公开快照链接；复制、浏览器、系统分享共用同一结果。
//

import SwiftUI

/// Sheet 只读取所展示的内容身份，当前阅读选择变化不会替换已生成的链接。
struct DailyRadarShareSheet: View {
    let taskStore: DailyRadarShareTaskStore
    let identity: String
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let job = taskStore.jobs[identity] {
                VStack(alignment: .leading, spacing: 16) {
                    header(job)
                    coverPreview(job)
                    stateContent(job)
                    sharingFooter(job)
                    actions(job)
                }
            }
        }
        .padding(22)
        .frame(width: 524)
    }

    private func header(_ job: DailyRadarShareJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("dailyRadar.share.title").font(.title3.weight(.semibold))
                Text(verbatim: job.report.title.replacingOccurrences(of: "\n", with: ""))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            SheetCloseButton(action: { dismiss() })
        }
    }

    private func coverPreview(_ job: DailyRadarShareJob) -> some View {
        let article = job.report.presentationMarkdown.flatMap(DailyRadarArticle.parse)
        return Group {
            if let image = job.coverImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if case .success(let response) = job.state {
                // 恢复链接不依赖重新渲染；预览读取原已发布封面，离线失败也不阻塞链接操作。
                AsyncImage(url: response.heroPNGURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.primary.opacity(0.04)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.04))
                    .overlay {
                        if job.state.isRunning { ProgressView().controlSize(.small) }
                    }
            }
        }
        .frame(width: 480, height: 252)
        // 文字只叠在预览层；上传 PNG 保持原样，避免网页重复叠字与快照 hash 冲突。
        .overlay {
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: (article?.title ?? job.report.title).replacingOccurrences(of: "\n", with: " "))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                let summary = article?.summary ?? job.report.summary
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            // 封面始终是深色画面，局部语义色跟随深色环境以保证浅色主题下可读。
            .environment(\.colorScheme, .dark)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stateContent(_ job: DailyRadarShareJob) -> some View {
        switch job.state {
        case .creating:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("dailyRadar.share.creating").font(.callout)
            }
        case .success(let response):
            VStack(alignment: .leading, spacing: 8) {
                Text("dailyRadar.share.ready")
                    .font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    CopyFeedbackButton(
                        providesContent: { response.shareURL.absoluteString },
                        tooltip: "repo.share.success.copyLink"
                    ) { didCopy in
                        HStack(spacing: 10) {
                            Text(verbatim: response.shareURL.absoluteString)
                                .font(.callout.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("repo.share.success.copyLink"))
                    Button {
                        NSWorkspace.shared.open(response.shareURL)
                    } label: {
                        Label("repo.share.success.openInBrowser", systemImage: "arrow.up.right.square")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .foregroundStyle(.secondary)
                    .help("repo.share.success.openInBrowser")
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        case .failure(let error):
            Label(LocalizedStringKey(error.localizationKey), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 说明允许换行，分享按钮保留完整标签，避免长语言把操作挤到下一行。
    private func sharingFooter(_ job: DailyRadarShareJob) -> some View {
        HStack(spacing: 12) {
            Text("dailyRadar.share.privacy")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .success(let response) = job.state {
                ShareLink(item: response.shareURL) {
                    Label("dailyRadar.share.system", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
            }
        }
    }

    /// 失败操作仍逐行右对齐，为 17 种语言保留完整标签。
    @ViewBuilder
    private func actions(_ job: DailyRadarShareJob) -> some View {
        if case .failure = job.state {
            VStack(alignment: .trailing, spacing: 10) {
                Button("settings.navigation.item.customServices") {
                    dismiss()
                    AppDelegate.openSettingsWindow(target: "services")
                }
                Button("action.retry", action: onRetry)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
