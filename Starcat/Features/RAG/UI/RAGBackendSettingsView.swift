//
//  RAGBackendSettingsView.swift
//  Starcat
//
//  RAG「检索」页中的索引与自托管后端配置。
//
//  关键约束：
//  - SQLite 是零配置默认值，Meilisearch / Qdrant 仅在用户主动选择时显示连接字段。
//  - API Key 继续写入 Keychain，端点与后端选择继续由 `AppSettings` 持久化。
//  - 切换后端不会自动重建索引，只给出明确状态，由用户决定何时执行重建。
//

import SwiftUI

/// 将原 AI 页中的 RAG 后端配置归回 RAG「检索」，避免基础模型设置混入知识库基础设施。
struct RAGBackendSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @State private var isStorageExpanded = false

    @State private var connections = RAGBackendConnectionSettingsModel()
    @State private var keywordNeedsRebuild = false
    @State private var vectorNeedsRebuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("settings.ai.models.embedding.title") {
                let model = settings.resolvedAITask(settings.aiEmbeddingTask, type: .embedding).resolvedModelName
                Text(model.isEmpty ? String.l10n("settings.retrieval.index.noModel") : model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            KnowledgeRAGIndexSettingsSummary(showsControls: false)
            Divider()
            // 只折叠存储大组；远程连接字段随当前存储直接展开，不再嵌套折叠。
            Button {
                isStorageExpanded.toggle()
            } label: {
                HStack {
                    Text("settings.retrieval.storage.configuration").foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(storageSummary).foregroundStyle(.secondary)
                    Image(systemName: isStorageExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityValue(Text(LocalizedStringKey(isStorageExpanded ? "settings.retrieval.expanded" : "settings.retrieval.collapsed")))
            if isStorageExpanded {
                Text("settings.retrieval.storage.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                storageFields
            }
        }
        .task { connections.load(settings: settings) }
        .onDisappear {
            connections.keywordTest.invalidate()
            connections.vectorTest.invalidate()
        }
    }

    private var storageSummary: String {
        let configuration = settings.ragBackendConfiguration
        let keyword = configuration.keywordBackend == .sqliteFTS5 ? "SQLite FTS5" : "Meilisearch"
        let vector = configuration.vectorBackend == .sqlite ? "SQLite BLOB" : "Qdrant"
        return "\(keyword) · \(vector)"
    }

    /// 连接字段编辑草稿，后端选择与 SQLite 回退保留原有即时生效行为。
    private var storageFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("settings.retrieval.storage.keyword")
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                Picker("settings.retrieval.storage.keyword", selection: keywordBackendBinding) {
                    Text("SQLite FTS5").tag(RAGKeywordBackend.sqliteFTS5)
                    Text("Meilisearch").tag(RAGKeywordBackend.meilisearch)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.vertical, 8)

            if settings.ragBackendConfiguration.keywordBackend == .meilisearch {
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.endpoint", text: meilisearchEndpointBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.index", text: meilisearchIndexBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(
                    titleKey: "settings.services.apiKey",
                    text: Binding(get: { connections.meilisearchAPIKey }, set: { connections.meilisearchAPIKey = $0 }),
                    isSecure: true
                )
                .padding(.vertical, 8)
                Divider()
                backendActionRow(
                    id: "meilisearch",
                    label: "settings.connection.testAndSave",
                    status: backendStatus(connections.keywordTest, needsRebuild: keywordNeedsRebuild)
                ) {
                    await testMeilisearch()
                }
                .padding(.vertical, 8)
            }

            Divider()

            HStack(spacing: 12) {
                Text("settings.retrieval.storage.vector")
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                Picker("settings.retrieval.storage.vector", selection: vectorBackendBinding) {
                    Text("SQLite BLOB").tag(RAGVectorBackend.sqlite)
                    Text("Qdrant").tag(RAGVectorBackend.qdrant)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.vertical, 8)

            Text("settings.retrieval.storage.vectorHint")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.ragBackendConfiguration.vectorBackend == .qdrant {
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.endpoint", text: qdrantEndpointBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.collection", text: qdrantCollectionBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(titleKey: "settings.rag.backends.vectorName", text: qdrantVectorNameBinding)
                    .padding(.vertical, 8)
                Divider()
                RAGSettingsConnectionField(
                    titleKey: "settings.services.apiKey",
                    text: Binding(get: { connections.qdrantAPIKey }, set: { connections.qdrantAPIKey = $0 }),
                    isSecure: true
                )
                .padding(.vertical, 8)
                Divider()
                backendActionRow(
                    id: "qdrant",
                    label: "settings.connection.testAndSave",
                    status: backendStatus(connections.vectorTest, needsRebuild: vectorNeedsRebuild)
                ) {
                    await testQdrant()
                }
                .padding(.vertical, 8)
            }

            Divider()
            Toggle("settings.rag.backends.fallback", isOn: fallbackBinding)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(connections.keywordTest.isSaving || connections.vectorTest.isSaving)
    }

    private func backendActionRow(
        id: String,
        label: LocalizedStringKey,
        status: RAGBackendTestStatus?,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        let test = id == "meilisearch" ? connections.keywordTest : connections.vectorTest
        return HStack(alignment: .center, spacing: 8) {
            if test.isTesting {
                ProgressView().controlSize(.small)
                Text("settings.services.summary.checking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                backendStatusLabel(status)
            }
            Spacer(minLength: 8)
            Button {
                Task { await action() }
            } label: {
                Text(label)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize()
            .disabled(test.isTesting)
        }
    }

    /// 状态色仅用于图标；正文保持次级色，避免错误文案形成大面积高饱和警示。
    @ViewBuilder
    private func backendStatusLabel(_ status: RAGBackendTestStatus?) -> some View {
        if let status {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: status.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.badgeColor)
                    .font(.callout)
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        }
    }

    private var keywordBackendBinding: Binding<RAGKeywordBackend> {
        Binding(
            get: { settings.ragBackendConfiguration.keywordBackend },
            set: { value in
                var configuration = settings.ragBackendConfiguration
                configuration.keywordBackend = value
                settings.ragBackendConfiguration = configuration
                connections.keywordTest.invalidate()
                keywordNeedsRebuild = value == .meilisearch
            }
        )
    }

    private var vectorBackendBinding: Binding<RAGVectorBackend> {
        Binding(
            get: { settings.ragBackendConfiguration.vectorBackend },
            set: { value in
                var configuration = settings.ragBackendConfiguration
                configuration.vectorBackend = value
                settings.ragBackendConfiguration = configuration
                connections.vectorTest.invalidate()
                vectorNeedsRebuild = value == .qdrant
            }
        )
    }

    private var fallbackBinding: Binding<Bool> {
        backendBinding(\.fallbackToSQLite)
    }

    private var meilisearchEndpointBinding: Binding<String> {
        Binding(get: { connections.meilisearch.endpoint }, set: { connections.meilisearch.endpoint = $0 })
    }

    private var meilisearchIndexBinding: Binding<String> {
        Binding(get: { connections.meilisearch.indexName }, set: { connections.meilisearch.indexName = $0 })
    }

    private var qdrantEndpointBinding: Binding<String> {
        Binding(get: { connections.qdrant.endpoint }, set: { connections.qdrant.endpoint = $0 })
    }

    private var qdrantCollectionBinding: Binding<String> {
        Binding(get: { connections.qdrant.collectionName }, set: { connections.qdrant.collectionName = $0 })
    }

    private var qdrantVectorNameBinding: Binding<String> {
        Binding(get: { connections.qdrant.vectorName }, set: { connections.qdrant.vectorName = $0 })
    }

    private func backendBinding<Value>(
        _ keyPath: WritableKeyPath<RAGBackendConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.ragBackendConfiguration[keyPath: keyPath] },
            set: { value in
                var configuration = settings.ragBackendConfiguration
                configuration[keyPath: keyPath] = value
                settings.ragBackendConfiguration = configuration
            }
        )
    }

    private func backendStatus(_ test: SettingsConnectionTest<Void>, needsRebuild: Bool) -> RAGBackendTestStatus? {
        if let message = test.errorMessage { return .failure(message) }
        if test.result != nil { return .success }
        return needsRebuild ? .rebuildRequired : nil
    }

    private func testMeilisearch() async {
        await connections.testMeilisearch(settings: settings) { configuration, key in
            try await MeilisearchRAGProvider(
                configuration: configuration, apiKey: key,
                repository: dependencies.ragChunkRepository
            ).testConnection()
        }
    }

    private func testQdrant() async {
        await connections.testQdrant(settings: settings) { configuration, key in
            try await QdrantRAGProvider(
                configuration: configuration, apiKey: key,
                repository: dependencies.ragChunkRepository
            ).testConnection()
        }
    }
}
