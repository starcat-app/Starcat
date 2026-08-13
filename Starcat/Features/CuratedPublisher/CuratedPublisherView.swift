//
//  CuratedPublisherView.swift
//  Starcat
//
//  维护者专用的 AI 精选发布台：左栏输入与模型，中栏证据复核，右栏 Weekly 发布。
//
//  视觉层明确分开“AI 甄别”和“服务端发布”，避免连接失败让用户误以为项目识别
//  依赖 weekly-api；所有可能影响全体用户的动作集中在最右栏。
//

import SwiftUI

enum CuratedPublisherWindow {
    static let id = "curated-publisher"
}

/// 三栏发布工作台。访问控制在场景根部和 Session 执行层各校验一次。
struct CuratedPublisherView: View {
    @Bindable var identification: CuratedProjectIdentificationSession
    @Bindable var publisher: CuratedPublisherSession

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    @State private var adminKeyDraft = ""
    @State private var isCreatingSource = false

    var body: some View {
        Group {
            if CuratedPublisherAccessPolicy.canAccess(userID: currentUserID) {
                authorizedContent
            } else {
                ContentUnavailableView(
                    "curatedPublisher.accessDenied.title",
                    systemImage: "lock.shield",
                    description: Text("curatedPublisher.accessDenied.description")
                )
            }
        }
        .task(id: currentUserID) {
            configureDefaultModel()
            await publisher.bootstrap(currentUserID: currentUserID)
        }
        .sheet(isPresented: $isCreatingSource) {
            CuratedPublisherCreateSourceSheet(
                publisher: publisher,
                currentUserID: currentUserID
            )
        }
    }

    private var currentUserID: Int64? { authSession.state.user?.id }

    private var authorizedContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView { inputColumn.padding(16) }
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 390)

                reviewColumn
                    .padding(16)
                    .frame(minWidth: 430, idealWidth: 560, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

                ScrollView { publishColumn.padding(16) }
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 400)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
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
                identification.clear()
                publisher.clearDraft()
            }
            .buttonStyle(.bordered)
            .disabled(identification.isRunning || publisher.operation != .idle)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var connectionBadge: some View {
        Label(connectionTitle, systemImage: connectionIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(publisher.isAdminConnected ? Color.green : Color.secondary)
    }

    private var connectionTitle: String {
        if publisher.isAdminConnected { return String.l10n("curatedPublisher.connection.connected") }
        if publisher.hasStoredAdminCredential { return String.l10n("curatedPublisher.connection.stored") }
        return String.l10n("curatedPublisher.connection.disconnected")
    }

    private var connectionIcon: String {
        if publisher.isAdminConnected { return "checkmark.circle.fill" }
        if publisher.hasStoredAdminCredential { return "key.fill" }
        return "circle.dashed"
    }

    // MARK: - Input

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            columnHeader(
                number: 1,
                title: "curatedPublisher.aiInput.title",
                subtitle: "curatedPublisher.aiInput.subtitle"
            )

            modelMenu

            TextEditor(text: $identification.input)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 310)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor))
                }
                .accessibilityLabel(Text("curatedPublisher.clue.placeholder"))

            Text("curatedPublisher.aiInput.hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await identification.identify(
                        externalSearchProvider: settings.externalSearchDefaultProvider
                    )
                    guard identification.errorMessage == nil else { return }
                    await publisher.activatePublishing(
                        findings: identification.publishableFindings,
                        currentUserID: currentUserID
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    if identification.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkle.magnifyingglass")
                    }
                    Text(identification.isRunning
                        ? identificationPhaseTitle
                        : String.l10n("curatedPublisher.action.aiIdentify"))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                identification.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || identification.isRunning
                    || identification.selectedModelID == nil
            )

            if let error = identification.errorMessage {
                errorText(error)
            }
        }
    }

    private var modelMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("curatedPublisher.aiInput.model")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(dependencies.knowledgeRAGChatModels) { model in
                    Button {
                        identification.selectedModelID = model.id
                    } label: {
                        if model.id == identification.selectedModelID {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            } label: {
                HStack {
                    Label(selectedModelName, systemImage: "brain.head.profile")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .disabled(identification.isRunning || dependencies.knowledgeRAGChatModels.isEmpty)
        }
    }

    private var selectedModelName: String {
        dependencies.knowledgeRAGChatModels
            .first { $0.id == identification.selectedModelID }?.name ?? "—"
    }

    private var identificationPhaseTitle: String {
        switch identification.phase {
        case .idle: String.l10n("curatedPublisher.action.aiIdentify")
        case .understanding: String.l10n("curatedPublisher.aiPhase.understanding")
        case .searching(let completed, let total):
            String(format: String.l10n("curatedPublisher.aiPhase.searchingFormat"), completed, total)
        case .judging: String.l10n("curatedPublisher.aiPhase.judging")
        }
    }

    // MARK: - Review

    private var reviewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader(
                number: 2,
                title: "curatedPublisher.review.title",
                subtitle: "curatedPublisher.review.subtitle"
            )
            .padding(.bottom, 14)

            if identification.findings.isEmpty {
                ContentUnavailableView(
                    "curatedPublisher.review.emptyTitle",
                    systemImage: "checklist",
                    description: Text("curatedPublisher.review.emptyDescription")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                resultSummary
                    .padding(.bottom, 12)

                // 结果列表与证据区独立滚动，避免批量甄别后证据被长列表挤到窗口之外。
                VSplitView {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(identification.findings) { finding in
                                findingCard(finding)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(minHeight: 180, idealHeight: 340)

                    if let selected = identification.selectedFinding {
                        ScrollView {
                            findingDetail(selected)
                                .padding(.top, 12)
                        }
                        .frame(minHeight: 150, idealHeight: 210, maxHeight: 280)
                    }
                }
            }
        }
    }

    private var resultSummary: some View {
        HStack(spacing: 14) {
            summaryMetric(
                value: identification.findings.filter { $0.status == .confirmed }.count,
                label: "curatedPublisher.review.confirmed",
                color: .green
            )
            summaryMetric(
                value: identification.findings.filter { $0.status == .needsReview }.count,
                label: "curatedPublisher.review.needsReview",
                color: .orange
            )
            summaryMetric(
                value: identification.findings.filter { $0.status == .notFound }.count,
                label: "curatedPublisher.review.notFound",
                color: .secondary
            )
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryMetric(value: Int, label: LocalizedStringKey, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(.title3.weight(.bold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func findingCard(_ finding: CuratedProjectFinding) -> some View {
        let isSelected = identification.selectedFindingID == finding.id
        let isIncluded = identification.includedFindingIDs.contains(finding.id)
        return HStack(alignment: .center, spacing: 9) {
            Button {
                identification.toggleIncluded(finding)
                publisher.setPreparedFindings(identification.publishableFindings)
            } label: {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!finding.isPublishable)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    statusBadge(finding.status)
                }
                Text(finding.repository?.card.fullName ?? finding.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear)
        }
        // 卡片负责切换详情，勾选按钮保持独立操作，避免嵌套 Button 造成点击事件冲突。
        .contentShape(Rectangle())
        .onTapGesture {
            identification.selectedFindingID = finding.id
        }
    }

    private func statusBadge(_ status: CuratedProjectIdentificationStatus) -> some View {
        let configuration: (String, String, Color) = switch status {
        case .confirmed: ("curatedPublisher.review.confirmed", "checkmark.seal.fill", .green)
        case .needsReview: ("curatedPublisher.review.needsReview", "exclamationmark.triangle.fill", .orange)
        case .notFound: ("curatedPublisher.review.notFound", "minus.circle", .secondary)
        }
        return Label(String.l10n(configuration.0), systemImage: configuration.1)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(configuration.2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(configuration.2.opacity(0.10), in: Capsule())
    }

    private func findingDetail(_ finding: CuratedProjectFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("curatedPublisher.review.evidenceTitle")
                .font(.subheadline.weight(.semibold))
            Text(finding.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !finding.evidence.isEmpty {
                ForEach(finding.evidence) { evidence in
                    Link(destination: evidence.url) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "link")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(evidence.title).lineLimit(1)
                                if let snippet = evidence.snippet, !snippet.isEmpty {
                                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if finding.status != .confirmed {
                Divider()
                if !finding.candidates.isEmpty {
                    Text("curatedPublisher.review.candidates")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(finding.candidates, id: \.identity) { candidate in
                        Button {
                            identification.confirmCandidate(candidate, for: finding.id)
                            publisher.setPreparedFindings(identification.publishableFindings)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.shield")
                                Text(candidate.card.fullName)
                                Spacer()
                                Text(candidate.card.starsCount.formatted())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("https://github.com/owner/repo", text: $identification.manualRepositoryURL)
                        .textFieldStyle(.roundedBorder)
                    Button("curatedPublisher.action.verify") {
                        Task {
                            await identification.verifyManualRepository()
                            publisher.setPreparedFindings(identification.publishableFindings)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(identification.manualRepositoryURL.isEmpty)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Publish

    private var publishColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            columnHeader(
                number: 3,
                title: "curatedPublisher.publish.title",
                subtitle: "curatedPublisher.publish.subtitle"
            )
            adminConnectionSection

            HStack(spacing: 8) {
                Picker("curatedPublisher.source.title", selection: $publisher.selectedSourceCode) {
                    ForEach(publisher.sources) { source in
                        Label(localizedName(for: source), systemImage: sourceIcon(for: source))
                            .tag(Optional(source.code))
                    }
                }
                .frame(maxWidth: .infinity)
                .controlSize(.regular)
                .disabled(!publisher.isAdminConnected || publisher.operation != .idle)
                Button {
                    isCreatingSource = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("curatedPublisher.source.create")
                .disabled(!publisher.isAdminConnected || publisher.operation != .idle)
            }

            publishPreview

            Label("curatedPublisher.publish.warning", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            if let error = publisher.errorMessage { errorText(error) }

            Button {
                Task { await publisher.publish(currentUserID: currentUserID) }
            } label: {
                HStack(spacing: 8) {
                    if publisher.operation == .publishing || publisher.operation == .polling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text("curatedPublisher.action.publish")
                    Spacer()
                    Text(publisher.preparedFindings.count.formatted())
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!publisher.canPublish)

            if let batch = publisher.batch { batchStatus(batch) }
        }
    }

    private var adminConnectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if publisher.isAdminConnected {
                    HStack {
                        Label("curatedPublisher.connection.ready", systemImage: "lock.shield.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("curatedPublisher.action.disconnect", role: .destructive) {
                            publisher.disconnect()
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
                        Button("curatedPublisher.action.connect") {
                            Task {
                                await publisher.connect(adminKey: adminKeyDraft, currentUserID: currentUserID)
                                if publisher.isAdminConnected { adminKeyDraft = "" }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(adminKeyDraft.isEmpty || publisher.operation != .idle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("curatedPublisher.connection.title", systemImage: "server.rack")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var publishPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("curatedPublisher.preview.title").font(.headline)
                Spacer()
                Text(publisher.preparedFindings.count.formatted())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(publisher.preparedFindings.prefix(8)) { finding in
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.secondary)
                    Text(finding.repository?.card.fullName ?? "—")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
            }
            if publisher.preparedFindings.count > 8 {
                Text(String(
                    format: String.l10n("curatedPublisher.preview.moreFormat"),
                    publisher.preparedFindings.count - 8
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func batchStatus(_ batch: CuratedPublisherBatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(batchStatusTitle(batch.status), systemImage: batchStatusIcon(batch.status))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(batchStatusColor(batch.status))
                Spacer(minLength: 8)
                Text(String(
                    format: String.l10n("curatedPublisher.batch.summaryFormat"),
                    batch.success,
                    batch.total,
                    batch.discarded
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(batch.batchID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            ForEach(batch.items.filter { $0.lastErrorMessage != nil }, id: \.id) { item in
                Text("\(item.normalizedFullName): \(item.lastErrorMessage ?? "")")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !batch.status.isTerminal, publisher.operation == .idle {
                HStack {
                    Spacer()
                    Button("curatedPublisher.action.retryStatus") {
                        Task { await publisher.retryBatchStatus(currentUserID: currentUserID) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func configureDefaultModel() {
        guard identification.selectedModelID == nil else { return }
        let models = dependencies.knowledgeRAGChatModels
        identification.selectedModelID = models.first(where: {
            $0.providerID == settings.aiChatTask.providerID
                && $0.name == settings.aiChatTask.resolvedModelName
        })?.id ?? models.first?.id
    }

    private func columnHeader(number: Int, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number.formatted())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func localizedName(for source: CuratedPublisherSource) -> String {
        locale.identifier.lowercased().hasPrefix("zh") ? source.displayNameZH : source.displayNameEN
    }

    private func sourceIcon(for source: CuratedPublisherSource) -> String {
        // 历史 AI 来源保存的是业务 icon key；UI 统一映射成有效的 SF Symbol。
        source.iconKey == "ai-intelligence" ? "sparkles" : source.iconKey
    }

    private func errorText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
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

/// 新增分类 Sheet。只采集服务端契约允许的三个字段。
private struct CuratedPublisherCreateSourceSheet: View {
    @Bindable var publisher: CuratedPublisherSession
    let currentUserID: Int64?

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var displayNameZH = ""
    @State private var displayNameEN = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("curatedPublisher.source.create", systemImage: "folder.badge.plus")
                    .font(.headline)
                Spacer()
                SheetCloseButton(action: { dismiss() })
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            Form {
                TextField("curatedPublisher.source.code", text: $code)
                TextField("curatedPublisher.source.nameZH", text: $displayNameZH)
                TextField("curatedPublisher.source.nameEN", text: $displayNameEN)
                Text("curatedPublisher.source.codeHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("curatedPublisher.source.create") {
                    Task {
                        if await publisher.createSource(
                            code: code,
                            displayNameZH: displayNameZH,
                            displayNameEN: displayNameEN,
                            currentUserID: currentUserID
                        ) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || displayNameZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || displayNameEN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || publisher.operation != .idle
                )
            }
            .padding(16)
        }
        .frame(width: 440, height: 330)
    }
}
