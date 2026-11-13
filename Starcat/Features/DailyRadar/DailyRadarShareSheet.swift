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
                    Text("dailyRadar.share.privacy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        Group {
            if let image = job.coverImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.04))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: 480, height: 252)
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
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(Text("repo.share.success.copyLink"))
            }
        case .failure(let error):
            Label(LocalizedStringKey(error.localizationKey), systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 操作逐行右对齐，为 17 种语言保留单行完整标签，不靠压缩字号适配。
    private func actions(_ job: DailyRadarShareJob) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            switch job.state {
            case .creating:
                EmptyView()
            case .success(let response):
                Button {
                    NSWorkspace.shared.open(response.shareURL)
                } label: {
                    Label("repo.share.success.openInBrowser", systemImage: "arrow.up.right.square")
                }
                ShareLink(item: response.shareURL) {
                    Label("dailyRadar.share.system", systemImage: "square.and.arrow.up")
                }
            case .failure:
                Button("settings.navigation.item.customServices") {
                    dismiss()
                    AppDelegate.openSettingsWindow(target: "services")
                }
                Button("action.retry", action: onRetry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
