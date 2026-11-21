import SwiftUI
import TaxData
import UniformTypeIdentifiers

public struct VolumeManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable public var corpus: CorpusController

    @State private var isShowingFileImporter = false
    @State private var activeDownloads: Set<Int> = []
    @State private var batchStatus: String?
    @State private var errorMessage: String?

    public init(corpus: CorpusController) {
        self.corpus = corpus
    }

    public var body: some View {
        NavigationStack {
            List {
                statusAndActionsSection
                batchDownloadSection
                gpoCatalogSection
                if !corpus.importedSources.isEmpty {
                    importedSourcesSection
                }
            }
            .navigationTitle("Corpora & Treasury Reg Volumes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.xml, .folder],
                allowsMultipleSelection: true
            ) { result in
                handleLocalImport(result)
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 580)
        #endif
    }

    private var statusAndActionsSection: some View {
        Section("Offline Index, Spotlight & Siri") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(corpus.database.totalSectionCount()) Sections Indexed Offline")
                        .font(.headline)
                    Text("SQLite FTS5 + CoreSpotlight + Apple Intelligence AppEntity index")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await corpus.reindexSpotlight() }
                } label: {
                    if corpus.isIndexingSpotlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync Spotlight & Siri", systemImage: "sparkles")
                    }
                }
                .disabled(corpus.isIndexingSpotlight)
            }

            Button {
                isShowingFileImporter = true
            } label: {
                Label("Import Local XML File(s) or Folder (USLM / CFR / eCFR)…", systemImage: "folder.badge.plus")
            }

            if let batchStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(batchStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var batchDownloadSection: some View {
        Section("One-Click GPO Bulk Presets (govinfo.gov)") {
            Button {
                let missingLLM = CFRCatalog.title26Volumes.filter { spec in
                    spec.isCoreLLMVolume && !isVolumeImported(spec.volume)
                }
                Task { await downloadBatch(missingLLM, label: "Core LL.M. Volumes") }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Download Missing Core Tax LL.M. Volumes", systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Covers Corporate (610), Partnership (620), Fed Income (640), International (670) & Procedure (675)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!activeDownloads.isEmpty || batchStatus != nil)

            Button {
                let missingAll = CFRCatalog.title26Volumes.filter { !isVolumeImported($0.volume) }
                Task { await downloadBatch(missingAll, label: "All Title 26 Volumes") }
            } label: {
                Label("Download All Remaining Title 26 CFR Volumes (Vols 1–22)", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(!activeDownloads.isEmpty || batchStatus != nil)
        }
    }

    private var gpoCatalogSection: some View {
        Section("Title 26 CFR Volumes (GPO Official XML)") {
            ForEach(CFRCatalog.title26Volumes) { spec in
                let imported = isVolumeImported(spec.volume)
                let downloading = activeDownloads.contains(spec.volume)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Vol. \(spec.volume) — \(spec.scope)")
                                .font(.subheadline.weight(.semibold))
                            if imported {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        Text(spec.topics)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !spec.courses.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(spec.courses, id: \.self) { course in
                                    Text(course)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                    }

                    Spacer()

                    if downloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(imported ? "Refresh" : "Download") {
                            Task { await downloadSingle(spec) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var importedSourcesSection: some View {
        Section("Currently Imported Files") {
            ForEach(corpus.importedSources) { src in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(src.title)
                            .font(.subheadline.weight(.medium))
                        Text("\(src.sourceID) • \(src.sectionCount) sections")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        try? corpus.database.removeSource(src.sourceID)
                        corpus.refreshMetadata()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Actions

    private func isVolumeImported(_ vol: Int) -> Bool {
        let token = "title26-vol\(vol).xml"
        return corpus.importedSources.contains { $0.sourceID.lowercased().hasSuffix(token) }
    }

    private func downloadSingle(_ spec: CFRVolumeSpec) async {
        errorMessage = nil
        activeDownloads.insert(spec.volume)
        defer { activeDownloads.remove(spec.volume) }

        do {
            let info = try await corpus.ingestor.downloadAndImportCFRVolume(spec)
            corpus.refreshMetadata()
            await corpus.reindexSpotlight(sourceID: info.sourceID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadBatch(_ specs: [CFRVolumeSpec], label: String) async {
        guard !specs.isEmpty else {
            batchStatus = nil
            return
        }
        errorMessage = nil
        let detectedYear = await corpus.ingestor.detectLatestCFRYear()
        for (idx, spec) in specs.enumerated() {
            batchStatus = "\(label): downloading Vol. \(spec.volume) (\(idx + 1) of \(specs.count))…"
            activeDownloads.insert(spec.volume)
            do {
                let info = try await corpus.ingestor.downloadAndImportCFRVolume(spec, year: detectedYear)
                corpus.refreshMetadata()
                await corpus.reindexSpotlight(sourceID: info.sourceID)
            } catch {
                errorMessage = "Vol. \(spec.volume): \(error.localizedDescription)"
            }
            activeDownloads.remove(spec.volume)
        }
        batchStatus = nil
    }

    private func handleLocalImport(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure(let err):
            errorMessage = err.localizedDescription
        case .success(let urls):
            Task {
                batchStatus = "Importing selected XML file(s)…"
                defer { batchStatus = nil }
                do {
                    for url in urls {
                        let imported = try await corpus.ingestor.importLocalPath(url)
                        corpus.refreshMetadata()
                        for src in imported {
                            await corpus.reindexSpotlight(sourceID: src.sourceID)
                        }
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
