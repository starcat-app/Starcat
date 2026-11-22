//
//  ReleaseWorkspaceAssets.swift
//  Starcat
//
//  当前版本的构建产物浏览器：组合筛选、本机匹配分组和真正的文件下载入口。
//

import SwiftUI

struct ReleaseWorkspaceAssets: View {
    let assets: [ReleaseAsset]
    @Binding var filter: ReleaseArtifactFilter
    let downloads: ReleaseWorkspaceDownloads
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        if assets.isEmpty {
            EmptyStateView(systemImage: "shippingbox", title: "releases.workspace.noAssets")
        } else {
            VStack(spacing: 0) {
                controls.padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                let builds = assets.map(ReleaseBuildArtifact.init).filter(filter.matches)
                if builds.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "releases.row.noMatchingAsset") {
                        Button("ai.usage.empty.clearFilters") { filter = ReleaseArtifactFilter() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let machine: ReleaseBuildArtifact.Architecture = LocalAIHardwareSupport.isAppleSilicon ? .arm64 : .intel
                    let recommended = builds.filter { $0.isRecommended(for: machine) }
                    let others = builds.filter { !$0.isRecommended(for: machine) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            group(recommended, heading: "releases.workspace.recommended", recommended: true)
                            group(others, heading: recommended.isEmpty ? nil : "releases.workspace.otherFiles", recommended: false)
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                searchField.frame(minWidth: scale.scaled(200))
                filterMenus.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField
                filterMenus
            }
        }
    }

    private var searchField: some View {
        ReleaseSearchField(label: "releases.assetFilter.placeholder", text: $filter.query)
    }

    private var filterMenus: some View {
        HStack(spacing: 14) {
            Picker("releases.workspace.platform", selection: $filter.platform) {
                Text("general.all").tag(nil as ReleaseBuildArtifact.Platform?)
                ForEach(ReleaseBuildArtifact.Platform.allCases, id: \.self) { platform in
                    Text(verbatim: platform.rawValue).tag(Optional(platform))
                }
            }
            Picker("releases.workspace.architecture", selection: $filter.architecture) {
                Text("general.all").tag(nil as ReleaseBuildArtifact.Architecture?)
                ForEach(ReleaseBuildArtifact.Architecture.allCases, id: \.self) { architecture in
                    Text(verbatim: architecture.rawValue).tag(Optional(architecture))
                }
            }
        }.controlSize(.small).font(scale.font(.caption))
    }

    @ViewBuilder private func group(_ builds: [ReleaseBuildArtifact], heading: LocalizedStringKey?, recommended: Bool) -> some View {
        if !builds.isEmpty {
            if let heading {
                Label(heading, systemImage: recommended ? "desktopcomputer" : "shippingbox")
                    .font(scale.font(.captionStrong)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
            ForEach(Array(builds.enumerated()), id: \.element.id) { index, build in
                ReleaseWorkspaceAssetRow(build: build, downloads: downloads)
                    .listRowSurface(index: index)
            }
        }
    }
}

/// 文件名优先，次行给出大小与识别出的目标；成功后保留 Finder 操作，同时允许再次下载。
private struct ReleaseWorkspaceAssetRow: View {
    let build: ReleaseBuildArtifact
    let downloads: ReleaseWorkspaceDownloads
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var hoveringDownload = false
    @FocusState private var focusingDownload: Bool

    private var state: ReleaseWorkspaceDownloads.State? { downloads.states[build.id] }

    private var fileBadge: some View {
        let style = ReleaseAssetIcon.workspaceStyle(for: build.asset.name)
        return RepoFileIcon(source: style.source, size: 19, templateTint: style.templateTint)
            .frame(width: 29, height: 29)
            .background(style.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        HStack(spacing: 9) {
            fileBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: build.asset.name)
                    .font(scale.font(.body, weight: .medium)).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).help(Text(verbatim: build.asset.name))
                let size = Int64(build.asset.size).formatted(.byteCount(style: .file).locale(locale))
                Text(verbatim: [size, build.platform?.rawValue, build.architecture?.rawValue]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(scale.font(.captionSmall)).foregroundStyle(.secondary)
                if case .failed(let reason) = state {
                    Text(verbatim: reason).font(scale.font(.captionSmall)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            // Finder 放在固定的复制和下载热区之前，完成、重试时两个常用按钮仍然对齐。
            if case .saved(let url) = state {
                Button { ReleaseAssetDownloadToastSupport.revealInFinder(url) } label: {
                    Label("settings.storage.revealInFinder", systemImage: "folder").labelStyle(.iconOnly)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(.secondary)
                .help("settings.storage.revealInFinder")
            }
            CopyFeedbackButton(providesContent: { build.asset.browserDownloadUrl }, tooltip: "releases.copyDownloadLink") { copied in
                Image(systemName: copied ? "checkmark.circle.fill" : "link")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("releases.copyDownloadLink"))
            downloadButton
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var actionLabel: LocalizedStringKey {
        switch state {
        case .running, .cancelling: "repo.files.cancelDownload"
        case .failed: "action.retry"
        default: "repo.files.inspector.download"
        }
    }

    private var downloadButton: some View {
        Button {
            if case .running = state {
                downloads.cancel(build.id)
            } else {
                Task { await downloads.start(build.asset) }
            }
        } label: {
            Group {
                switch state {
                case .running(let fraction) where !hoveringDownload && !focusingDownload:
                    ReleaseAssetDownloadProgressRing(progress: fraction, side: 16)
                case .running, .cancelling:
                    Image(systemName: "stop.circle.fill")
                        // 停止正在进行的下载使用红色动作语义，区别于灰色的普通下载入口。
                        .foregroundStyle(.red)
                case .failed:
                    Image(systemName: "arrow.clockwise")
                default:
                    Image(systemName: "arrow.down.to.line")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .focused($focusingDownload)
        .onHover { hoveringDownload = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveringDownload || focusingDownload)
        .disabled(state == .cancelling)
        .help(Text(actionLabel))
        .accessibilityLabel(Text(actionLabel))
        .accessibilityValue(progressDescription)
    }

    private var progressDescription: Text {
        if case .running(let fraction) = state {
            return Text(fraction, format: .percent.precision(.fractionLength(0)).locale(locale))
        }
        return Text(verbatim: "")
    }
}
