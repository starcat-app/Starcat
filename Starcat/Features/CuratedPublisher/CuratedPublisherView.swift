//
//  CuratedPublisherView.swift
//  Starcat
//
//  维护者专用精选发布台：左侧识别与官方核验，右侧分类、预览、发布与批次状态。
//
//  UI 只呈现 `CuratedPublisherSession` 的状态；权限、确认与发布守卫全部留在 Session，
//  防止窗口入口隐藏或 Button disabled 被绕过后出现越权提交。
//

import SwiftUI

enum CuratedPublisherWindow {
    static let id = "curated-publisher"
}

struct CuratedPublisherView: View {
    @Bindable var session: CuratedPublisherSession

    @Environment(AuthSession.self) private var authSession
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    @State private var adminKeyDraft = ""

    var body: some View {
        Group {
            if CuratedPublisherAccessPolicy.canAccess(userID: authSession.state.user?.id) {
                authorizedContent
            } else {
                ContentUnavailableView(
                    "curatedPublisher.accessDenied.title",
                    systemImage: "lock.shield",
                    description: Text("curatedPublisher.accessDenied.description")
                )
            }
        }
        .task(id: authSession.state.user?.id) {
            await session.bootstrap(currentUserID: authSession.state.user?.id)
        }
    }

    private var authorizedContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView {
                    discoveryColumn
                        .padding(24)
                }
                .frame(minWidth: 540, idealWidth: 680)

                ScrollView {
                    publishColumn
                        .padding(24)
                }
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 440)
                .background(.background.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("curatedPublisher.title")
                    .font(.title3.weight(.semibold))
                Text("curatedPublisher.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            connectionBadge
            Button("curatedPublisher.action.clear") {
                session.clearDraft()
            }
            .buttonStyle(.bordered)
            .disabled(session.operation != .idle)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var connectionBadge: some View {
        Label(
            session.isAdminConnected
                ? String.l10n("curatedPublisher.connection.connected")
                : String.l10n("curatedPublisher.connection.disconnected"),
            systemImage: session.isAdminConnected ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(session.isAdminConnected ? Color.green : Color.secondary)
    }

    private var discoveryColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("curatedPublisher.clue.title", step: 1)
            Text("curatedPublisher.clue.description")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $session.clue)
                .font(.body)
                .frame(minHeight: 116)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator)
                }
                .accessibilityLabel(Text("curatedPublisher.clue.placeholder"))

            HStack {
                Spacer()
                Button {
                    Task {
                        await session.resolveClue(
                            externalSearchProvider: settings.externalSearchDefaultProvider
                        )
                    }
                } label: {
                    operationLabel(
                        title: "curatedPublisher.action.resolve",
                        activeOperation: .resolving,
                        icon: "sparkle.magnifyingglass"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.clue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || session.operation != .idle)
            }

            if session.didFallbackFromWebSearch {
                Label("curatedPublisher.search.fallback", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !session.candidates.isEmpty {
                candidateSection
            }

            Divider()
            verificationSection
        }
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("curatedPublisher.candidates.title")
                .font(.headline)
            ForEach(session.candidates) { candidate in
                candidateButton(candidate)
            }
        }
    }

    private func candidateButton(_ candidate: RepositoryCandidate) -> some View {
        let isSelected = session.verifiedCandidate?.identity == candidate.identity
        return Button {
            session.selectCandidate(candidate)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.card.fullName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = candidate.card.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        if let language = candidate.card.language {
                            Label(language, systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Label(candidate.card.starsCount.formatted(), systemImage: "star.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("curatedPublisher.verify.title", step: 2)
            LabeledContent("curatedPublisher.verify.finalURL") {
                TextField("https://github.com/owner/repo", text: $session.finalGitHubURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 360)
            }
            HStack {
                verificationStatus
                Spacer()
                Button {
                    Task { await session.verifyFinalURL() }
                } label: {
                    operationLabel(
                        title: "curatedPublisher.action.verify",
                        activeOperation: .verifying,
                        icon: "checkmark.shield"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(session.finalGitHubURL.isEmpty || session.operation != .idle)
            }
            if let candidate = session.verifiedCandidate {
                repositoryPreview(candidate)
                TextField("curatedPublisher.field.displayTitle", text: $session.displayTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("curatedPublisher.field.sourceURL", text: $session.sourceURL)
                    .textFieldStyle(.roundedBorder)
                Toggle("curatedPublisher.confirm.official", isOn: $session.hasConfirmedOfficialRepository)
                    .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private var verificationStatus: some View {
        if session.verifiedCandidate != nil {
            Label("curatedPublisher.verify.passed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Label("curatedPublisher.verify.pending", systemImage: "shield")
                .foregroundStyle(.secondary)
        }
    }

    private func repositoryPreview(_ candidate: RepositoryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.card.fullName)
                .font(.headline)
            if let description = candidate.card.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let language = candidate.card.language { Text(language) }
                Label(candidate.card.starsCount.formatted(), systemImage: "star.fill")
                Label(candidate.card.forksCount.formatted(), systemImage: "tuningfork")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var publishColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            adminConnectionSection
            Divider()
            sectionTitle("curatedPublisher.publish.title", step: 3)

            Picker("curatedPublisher.source.title", selection: $session.selectedSourceCode) {
                ForEach(session.sources) { source in
                    Label(localizedName(for: source), systemImage: source.iconKey)
                        .tag(Optional(source.code))
                }
            }
            .disabled(!session.isAdminConnected || session.operation != .idle)

            if let source = session.selectedSource {
                LabeledContent("curatedPublisher.source.queue") {
                    Text("\(source.pending + source.processing + source.retrying)")
                }
                .font(.caption)
            }

            publishPreview

            Label("curatedPublisher.publish.warning", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            if let error = session.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Button {
                Task { await session.publish(currentUserID: authSession.state.user?.id) }
            } label: {
                operationLabel(
                    title: "curatedPublisher.action.publish",
                    activeOperation: .publishing,
                    icon: "paperplane.fill",
                    showsProgressForAnyBusyOperation: true
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!session.canPublish)

            if let batch = session.batch {
                batchStatus(batch)
            }
        }
    }

    private var adminConnectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if session.isAdminConnected {
                    Label("curatedPublisher.connection.ready", systemImage: "lock.shield.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Spacer()
                        Button("curatedPublisher.action.disconnect", role: .destructive) {
                            session.disconnect()
                        }
                    }
                } else {
                    SecureField("curatedPublisher.connection.keyPlaceholder", text: $adminKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("curatedPublisher.connection.keyHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task {
                                await session.connect(
                                    adminKey: adminKeyDraft,
                                    currentUserID: authSession.state.user?.id
                                )
                                if session.isAdminConnected { adminKeyDraft = "" }
                            }
                        } label: {
                            operationLabel(
                                title: "curatedPublisher.action.connect",
                                activeOperation: .connecting,
                                icon: "link"
                            )
                        }
                        .disabled(adminKeyDraft.isEmpty || session.operation != .idle)
                    }
                }
            }
        } label: {
            Label("curatedPublisher.connection.title", systemImage: "server.rack")
        }
    }

    private var publishPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("curatedPublisher.preview.title")
                .font(.headline)
            previewRow("curatedPublisher.preview.repository", value: session.verifiedCandidate?.card.fullName ?? "—")
            previewRow("curatedPublisher.preview.source", value: session.selectedSource.map(localizedName(for:)) ?? "—")
            previewRow("curatedPublisher.preview.titleField", value: session.displayTitle.isEmpty ? "—" : session.displayTitle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func previewRow(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }

    private func batchStatus(_ batch: CuratedPublisherBatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(batchStatusTitle(batch.status), systemImage: batchStatusIcon(batch.status))
                .font(.headline)
                .foregroundStyle(batchStatusColor(batch.status))
            Text(String(format: String.l10n("curatedPublisher.batch.summaryFormat"), batch.success, batch.total, batch.discarded))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(batch.batchID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ForEach(batch.items.filter { $0.lastErrorMessage != nil }, id: \.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.normalizedFullName)
                        .font(.caption.weight(.semibold))
                    Text([item.lastErrorCode, item.lastErrorMessage].compactMap { $0 }.joined(separator: ": "))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionTitle(_ key: LocalizedStringKey, step: Int) -> some View {
        HStack(spacing: 9) {
            Text("\(step)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(key)
                .font(.headline)
        }
    }

    private func operationLabel(
        title: LocalizedStringKey,
        activeOperation: CuratedPublisherOperation,
        icon: String,
        showsProgressForAnyBusyOperation: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            if session.operation == activeOperation
                || (showsProgressForAnyBusyOperation && session.operation != .idle) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
            }
            Text(title)
        }
    }

    private func localizedName(for source: CuratedPublisherSource) -> String {
        locale.identifier.lowercased().hasPrefix("zh") ? source.displayNameZH : source.displayNameEN
    }

    private func batchStatusTitle(_ status: CuratedPublisherBatchStatus) -> LocalizedStringKey {
        switch status {
        case .pending: "curatedPublisher.batch.pending"
        case .processing: "curatedPublisher.batch.processing"
        case .success: "curatedPublisher.batch.success"
        case .partialSuccess: "curatedPublisher.batch.partialSuccess"
        case .failed: "curatedPublisher.batch.failed"
        }
    }

    private func batchStatusIcon(_ status: CuratedPublisherBatchStatus) -> String {
        switch status {
        case .pending: "clock"
        case .processing: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .partialSuccess: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func batchStatusColor(_ status: CuratedPublisherBatchStatus) -> Color {
        switch status {
        case .pending, .processing: .secondary
        case .success: .green
        case .partialSuccess: .orange
        case .failed: .red
        }
    }
}
