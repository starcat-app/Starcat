//
//  DailyRecommendationCardsView.swift
//  Starcat
//
//  每日抽卡舞台：扇形卡背、3D 翻牌、卡槽归位与全部翻开。
//  底层抽样已完成，点击翻牌只揭示冻结批次，不临时请求或随机改变仓库。
//

import SwiftUI

/// 整窗透明覆盖层，不以普通 Sheet 或卡片网格代替抽卡主交互。
struct DailyRecommendationCardsView: View {
    @Bindable var store: DailyRecommendationStore
    let onClose: () -> Void
    let onOpen: (Repo) -> Void
    let onRetry: () async -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Namespace private var flight
    @State private var activeID: Int64?
    @State private var flipAngle = 0.0
    @State private var isFlipping = false
    @State private var pendingStar: RepoRecommendationItem?
    @State private var starringID: Int64?
    @State private var actionFailed = false
    @State private var floats = false
    @State private var drawTask: Task<Void, Never>?
    @State private var detailTask: Task<Void, Never>?
    @State private var openingDetail = false

    private var activeItem: RepoRecommendationItem? {
        store.visibleItems.first { $0.repoID == activeID }
    }

    private var isComplete: Bool { !store.visibleItems.isEmpty && store.unrevealedItems.isEmpty && activeID == nil }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DailyRecommendationBackdrop().ignoresSafeArea()
                // 产品要求透明暗色渐晕；仅作覆盖层隔离，不改变底层应用的主题。
                RadialGradient(colors: [.clear, .black.opacity(0.16)], center: .center,
                               startRadius: 100, endRadius: max(geometry.size.width, geometry.size.height))
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    header
                    if store.visibleItems.isEmpty {
                        emptyState
                    } else if isComplete {
                        collection
                    } else {
                        stage(height: max(240, min(350, geometry.size.height - 310)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if !store.visibleItems.isEmpty { tray }
                    footer
                }
                .padding(.horizontal, geometry.size.width < 900 ? 20 : 40)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { floats = true }
        }
        .onDisappear {
            detailTask?.cancel()
            detailTask = nil
            drawTask?.cancel()
            drawTask = nil
            isFlipping = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { floats = false }
        }
        .alert("recommendations.daily.starConfirm", isPresented: Binding(
            get: { pendingStar != nil },
            set: { if !$0 { pendingStar = nil } }
        )) {
            Button("common.cancel", role: .cancel) { pendingStar = nil }
            Button("recommendations.daily.star") {
                if let item = pendingStar { Task { await star(item) } }
                pendingStar = nil
            }
        } message: {
            Text(verbatim: pendingStar?.fullName ?? "")
        }
        .alert("recommendations.daily.actionFailed", isPresented: $actionFailed) {
            Button("common.ok", role: .cancel) {}
        }
        .onExitCommand(perform: onClose)
        .onChange(of: store.visibleItems.map(\.repoID)) { _, ids in
            if let activeID, !ids.contains(activeID) { self.activeID = nil }
        }
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                Text(store.state.generatedAt ?? Date(), format: .dateTime.year().month().day().locale(locale))
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                Text("recommendations.daily.title")
                    .font(interfaceScale.font(.workspaceTitle))
                Text("recommendations.daily.subtitle")
                    .font(interfaceScale.font(.body))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            SheetCloseButton(action: onClose)
        }
    }

    /// 一次只翻一张；已翻卡使用同一个 geometry ID 从舞台归入底部槽位。
    private func stage(height: CGFloat) -> some View {
        let width = height * 0.71
        return ZStack {
            ForEach(Array(0..<min(5, store.unrevealedItems.count)), id: \.self) { index in
                Button { drawNext() } label: {
                    cardBack
                        .frame(width: width, height: height)
                        .rotationEffect(.degrees(Double(index - 2) * 9))
                        .offset(x: CGFloat(index - 2) * 36, y: CGFloat(abs(index - 2)) * 10)
                        .offset(y: floats && !reduceMotion ? -5 : 0)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text("recommendations.daily.draw"))
                .disabled(isFlipping)
            }
            if let item = activeItem {
                ZStack {
                    cardBack.opacity(flipAngle < 90 ? 1 : 0)
                    cardFace(item)
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                        .opacity(flipAngle >= 90 ? 1 : 0)
                }
                .frame(width: width, height: height)
                .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .matchedGeometryEffect(id: item.repoID, in: flight)
                .zIndex(10)
                .offset(x: 80)
            }
        }
        .padding(.vertical, 12)
    }

    private var cardBack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
                .padding(9)
            VStack(spacing: 16) {
                BusinessIcon(.recommendations, pointSize: 40)
                Text(verbatim: "STARCAT")
                    .font(interfaceScale.font(.captionStrong))
                    .tracking(4)
                    .foregroundStyle(.secondary)
                Text("recommendations.daily.draw")
                    .font(interfaceScale.font(.body))
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }

    /// 卡面固定信息层级；无预生成总结时直接展示真实仓库描述，不标注 AI 生成。
    private func cardFace(_ item: RepoRecommendationItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RemoteAvatar(urlString: avatarURL(item), size: 32)
                Text(verbatim: item.fullName)
                    .font(interfaceScale.font(.rowTitle))
                    .lineLimit(2)
                    .help(item.fullName)
            }
            HStack {
                if let language = item.language {
                    Text(verbatim: language).lineLimit(1)
                }
                Spacer(minLength: 4)
                Label(item.stars.formatted(.number.locale(locale)), systemImage: "star")
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            Divider()
            Text(verbatim: item.description ?? String.l10n("recommendations.daily.noDescription"))
                .font(interfaceScale.font(.body))
                .lineLimit(3)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            Text("recommendations.daily.reason")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Button("recommendations.daily.details") { openDetail(item) }
                    .disabled(openingDetail)
                Spacer(minLength: 0)
                Button("recommendations.daily.star") { pendingStar = item }
                    .buttonStyle(.borderedProminent)
                    .disabled(starringID != nil || dependencies.starredRegistry.contains(ghRepoId: item.repoID))
            }
            Button("recommendations.daily.dismiss") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { activeID = nil }
                Task { await store.dismiss(item.repoID) }
            }
            .font(interfaceScale.font(.caption))
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.3)))
    }

    private var tray: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(store.visibleItems.enumerated()), id: \.element.repoID) { index, item in
                    let revealed = store.state.revealedIDs.contains(item.repoID)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(revealed ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
                        if revealed && activeID != item.repoID {
                            Button {
                                flipAngle = 180
                                withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { activeID = item.repoID }
                            } label: {
                                VStack(spacing: 6) {
                                    RemoteAvatar(urlString: avatarURL(item), size: 24)
                                    Text(verbatim: item.fullName.split(separator: "/").last.map(String.init) ?? item.fullName)
                                        .lineLimit(1)
                                }
                                .font(interfaceScale.font(.caption))
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .matchedGeometryEffect(id: item.repoID, in: flight)
                        } else {
                            Text(verbatim: String(format: "%02d", index + 1))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 76, height: 88)
                }
            }
            .padding(4)
            .frame(minWidth: 0)
        }
        .frame(height: 100)
        .scrollIndicators(.hidden)
    }

    private var collection: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300))], spacing: 16) {
                ForEach(store.visibleItems) { item in
                    cardFace(item).frame(height: 300)
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isLoading {
                Text("recommendations.daily.loading")
            } else {
                Text(LocalizedStringKey(store.accountID == nil ? "sidebar.loginPrompt" : store.errorKey ?? store.emptyKey))
                Button("recommendations.daily.retry") { Task { await onRetry() } }
            }
        }
        .font(interfaceScale.font(.body))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle("recommendations.daily.autoShow", isOn: Binding(
                get: { store.state.showsOnLaunch },
                set: { enabled in Task { await store.setShowsOnLaunch(enabled) } }
            ))
            .toggleStyle(.checkbox)
            .font(interfaceScale.font(.caption))
            .disabled(store.accountID == nil || store.isLoading)
            Spacer(minLength: 8)
            if let error = store.errorKey, !store.visibleItems.isEmpty {
                Text(LocalizedStringKey(error)).font(interfaceScale.font(.caption)).lineLimit(2)
            }
            Text(verbatim: "\(store.state.revealedIDs.intersection(Set(store.visibleItems.map(\.repoID))).count) / \(store.visibleItems.count)")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            if !store.visibleItems.isEmpty && !isComplete {
                Button("recommendations.daily.openAll") {
                    Task {
                        await store.revealAll()
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { activeID = nil }
                    }
                }
                Button("recommendations.daily.draw") { drawNext() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFlipping)
            }
            Button(isComplete ? "recommendations.daily.done" : "recommendations.daily.skip", action: onClose)
        }
    }

    private func drawNext() {
        guard !isFlipping else { return }
        guard let next = store.unrevealedItems.first else {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { activeID = nil }
            return
        }
        let accountID = store.accountID
        isFlipping = true
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45)) { activeID = nil }
        drawTask = Task {
            defer { isFlipping = false }
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, store.accountID == accountID,
                  store.visibleItems.contains(where: { $0.repoID == next.repoID }) else { return }
            flipAngle = 0
            activeID = next.repoID
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { flipAngle = 180 }
            await store.reveal(next.repoID)
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(500)) }
        }
    }

    private func avatarURL(_ item: RepoRecommendationItem) -> String? {
        guard let owner = item.fullName.split(separator: "/").first else { return nil }
        return "https://github.com/\(owner).png"
    }

    /// Manage README 缓存以 repos 为外键父表，必须先补元数据，再允许详情开始加载。
    /// 关闭抽卡层或切账号后不再导航；写入失败留在当前卡片，沿用已有错误提示。
    private func openDetail(_ item: RepoRecommendationItem) {
        guard !openingDetail, let account = store.accountID,
              dependencies.database.currentUserId == account else { return }
        let revision = dependencies.databaseScopeRevision
        openingDetail = true
        detailTask = Task {
            defer { openingDetail = false }
            guard !Task.isCancelled, store.accountID == account,
                  dependencies.databaseScopeRevision == revision else { return }
            do {
                let repo = try await dependencies.repoRepository.upsertRepoMetadataForLibrary(
                    repo: item.dailyRecommendationRepo, syncedAt: Date(), preservingExisting: true
                )
                guard !Task.isCancelled, store.accountID == account,
                      dependencies.database.currentUserId == account,
                      dependencies.databaseScopeRevision == revision else { return }
                onOpen(repo)
            } catch {
                guard !Task.isCancelled, store.accountID == account,
                      dependencies.databaseScopeRevision == revision else { return }
                actionFailed = true
            }
        }
    }

    /// 只有用户确认后才调用 Star 的既有权威写入路径，失败保留原卡片供重试。
    private func star(_ item: RepoRecommendationItem) async {
        guard starringID == nil,
              let account = store.accountID,
              dependencies.database.currentUserId == account,
              !dependencies.starredRegistry.contains(ghRepoId: item.repoID) else { return }
        let parts = item.fullName.split(separator: "/")
        guard parts.count == 2 else { return }
        starringID = item.repoID
        defer { starringID = nil }
        do {
            _ = try await dependencies.starActionService.star(
                owner: String(parts[0]), repo: String(parts[1]), displayedStarsCount: item.stars
            )
            guard store.accountID == account else { return }
            activeID = nil
            await store.excludeStarred(dependencies.starredRegistry.ids)
        } catch {
            if store.accountID == account { actionFailed = true }
        }
    }
}
