import SwiftUI
import TaxData

public struct ProvisionReaderView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("readerFontSize") private var readerFontSize: Double = 16.0

    public let route: ProvisionRoute
    public var document: Binding<TaxWorkflowDocument>?
    public let corpus: CorpusController
    public let isSplitSecondary: Bool
    public let isPopOutWindow: Bool
    public let onNavigate: (ProvisionRoute) -> Void
    public let onOpenCitation: ((CitationTarget, OpenDisposition) -> Void)?

    @State private var record: SectionRecord?
    @State private var compiledBlocks: [RenderedProvisionBlock] = []
    @State private var transientEdits: [String: AttributedString] = [:]
    @State private var relatedRegs: [SectionSummary] = []
    @State private var parentIRC: SectionSummary?
    @State private var adjacent: (previous: SectionSummary?, next: SectionSummary?) = (nil, nil)
    @State private var showNoteEditor: Bool = false
    @State private var showOfficialNotes: Bool = false
    @State private var inSectionFilter: String = ""
    @State private var highlightedAnchor: String?

    public init(
        route: ProvisionRoute,
        document: Binding<TaxWorkflowDocument>? = nil,
        corpus: CorpusController,
        isSplitSecondary: Bool = false,
        isPopOutWindow: Bool = false,
        onNavigate: @escaping (ProvisionRoute) -> Void,
        onOpenCitation: ((CitationTarget, OpenDisposition) -> Void)? = nil
    ) {
        self.route = route
        self.document = document
        self.corpus = corpus
        self.isSplitSecondary = isSplitSecondary
        self.isPopOutWindow = isPopOutWindow
        self.onNavigate = onNavigate
        self.onOpenCitation = onOpenCitation
    }

    private var hasSectionNote: Bool {
        guard let doc = document?.wrappedValue else { return false }
        return !doc.note(for: route.sectionID).characters.isEmpty
    }

    private var isRoutePinned: Bool {
        guard let doc = document?.wrappedValue else { return false }
        return doc.isPinned(route) || doc.hasAnyPin(forSectionID: route.sectionID)
    }

    public var body: some View {
        Group {
            if let record {
                loadedBody(record: record)
            } else {
                Color.clear
            }
        }
        .task(id: route.sectionID) {
            await loadSectionAsync(sectionID: route.sectionID, initialAnchor: route.anchor)
        }
        .onChange(of: route.anchor) { _, newAnchor in
            highlightedAnchor = newAnchor
        }
        .environment(\.openURL, OpenURLAction { url in
            handleCitationURL(url)
        })
    }

    @ViewBuilder
    private func loadedBody(record: SectionRecord) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                headerBar(record: record)
                Divider()
                crossReferenceStrip(record: record)
                subsectionJumpBar(provision: record.provision, proxy: proxy)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let document, (showNoteEditor || hasSectionNote) {
                            workflowNoteCard(sectionID: record.summary.id, document: document)
                                .padding(.leading, GutterProvisionSheetView.gutterWidth + 15)
                                .padding(.trailing, 20)
                                .padding(.vertical, 12)
                            Divider()
                        }

                        GutterProvisionSheetView(
                            blocks: compiledBlocks,
                            fontSize: readerFontSize,
                            highlightedAnchor: highlightedAnchor,
                            filterQueryLowercased: inSectionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                            document: document,
                            transientEdits: $transientEdits,
                            onOpenCitation: { target, disposition in
                                openTarget(target, disposition: disposition)
                            },
                            onPopOutCitation: { target in
                                if let sec = corpus.database.resolve(target) {
                                    openWindow(value: ProvisionRoute(sectionID: sec.id, anchor: target.subsectionAnchor))
                                }
                            }
                        )

                        if !record.provision.notes.isEmpty {
                            Divider()
                            officialNotesSection(notes: record.provision.notes)
                                .padding(.leading, GutterProvisionSheetView.gutterWidth + 15)
                                .padding(.trailing, 20)
                                .padding(.vertical, 14)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onChange(of: compiledBlocks.count) { _, _ in
                scrollToRouteAnchor(proxy: proxy)
            }
            .onChange(of: route.anchor) { _, _ in
                scrollToRouteAnchor(proxy: proxy)
            }
        }
    }

    // MARK: - Header & Text Size Controls

    @ViewBuilder
    private func headerBar(record: SectionRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary.displayTitle)
                    .font(.system(size: readerFontSize + 3, weight: .bold))
                if !record.summary.heading.isEmpty {
                    Text(record.summary.heading)
                        .font(.system(size: max(13, readerFontSize - 1), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 5) {
                TextField("Filter…", text: $inSectionFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 130)

                // Font Size Controls (⌘- / ⌘+)
                HStack(spacing: 2) {
                    Button {
                        readerFontSize = max(12, readerFontSize - 1.5)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .help("Smaller Text (⌘-)")

                    Button {
                        readerFontSize = min(30, readerFontSize + 1.5)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .help("Bigger Text (⌘+)")
                }

                Button {
                    if let prev = adjacent.previous {
                        onNavigate(ProvisionRoute(sectionID: prev.id))
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(adjacent.previous == nil)

                Button {
                    if let next = adjacent.next {
                        onNavigate(ProvisionRoute(sectionID: next.id))
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(adjacent.next == nil)

                if let document {
                    if document.wrappedValue.hasBlockEdits(forSectionID: record.summary.id) {
                        Button {
                            document.wrappedValue.resetBlockEdits(forSectionID: record.summary.id)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .help("Reset Line Breaks in This Section")
                    }

                    Button {
                        document.wrappedValue.togglePin(route)
                    } label: {
                        Image(systemName: isRoutePinned ? "pin.fill" : "pin")
                    }
                    .help("Pin")

                    Button {
                        showNoteEditor.toggle()
                    } label: {
                        Image(systemName: hasSectionNote ? "note.text" : "square.and.pencil")
                    }
                    .help("Notes")

                    if !isPopOutWindow && !isSplitSecondary {
                        Button {
                            let companion = corpus.defaultCompanionRoute(for: route)
                            document.wrappedValue.openInSplitPane(companion)
                        } label: {
                            Image(systemName: "rectangle.split.2x1")
                        }
                        .help("Split")
                    }
                }

                Button {
                    openWindow(value: route)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("New Window")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - IRC <-> Regs Strip

    @ViewBuilder
    private func crossReferenceStrip(record: SectionRecord) -> some View {
        if record.summary.corpus == .irc && !relatedRegs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(relatedRegs) { reg in
                        let regRoute = ProvisionRoute(sectionID: reg.id)
                        Button("§ \(reg.number)") {
                            if let document, !isPopOutWindow && !isSplitSecondary {
                                document.wrappedValue.openInSplitPane(regRoute)
                            } else {
                                onNavigate(regRoute)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(reg.heading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .background(.bar)
            Divider()
        } else if let parentIRC {
            let ircRoute = ProvisionRoute(sectionID: parentIRC.id)
            HStack(spacing: 8) {
                Button("\(parentIRC.displayTitle) — \(parentIRC.heading)") {
                    if let document, !isPopOutWindow && !isSplitSecondary {
                        document.wrappedValue.openInSplitPane(ircRoute)
                    } else {
                        onNavigate(ircRoute)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
        }
    }

    // MARK: - Subsection Jump Bar

    @ViewBuilder
    private func subsectionJumpBar(provision: Provision, proxy: ScrollViewProxy) -> some View {
        let topAnchors: [String] = {
            if !provision.children.isEmpty {
                return provision.children.compactMap { Provision.normalizeDesignator($0.value ?? $0.number) }
            }
            // For flat CFR sections, collect top-level lowercase letter gutter designators (a), (b), (c)...
            var seen = Set<String>()
            var out: [String] = []
            for block in compiledBlocks {
                if let tok = block.anchorPath,
                   tok.count == 1,
                   let ch = tok.first, ch.isLowercase,
                   seen.insert(tok).inserted {
                    out.append(tok)
                }
            }
            return out
        }()

        if !topAnchors.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(topAnchors, id: \.self) { subVal in
                        Button {
                            highlightedAnchor = subVal
                            proxy.scrollTo("anchor:\(subVal)", anchor: .top)
                        } label: {
                            Text("(\(subVal))")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    highlightedAnchor == subVal
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.secondary.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
            }
            .background(.bar)
            Divider()
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private func workflowNoteCard(sectionID: String, document: Binding<TaxWorkflowDocument>) -> some View {
        let noteBinding = Binding<AttributedString>(
            get: { document.wrappedValue.note(for: sectionID) },
            set: { document.wrappedValue.setNote($0, for: sectionID) }
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if document.wrappedValue.note(for: sectionID).characters.isEmpty {
                    Button("Close") { showNoteEditor = false }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: noteBinding)
                .font(.system(size: max(13, readerFontSize - 1)))
                .frame(minHeight: 72, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func officialNotesSection(notes: [DocumentNode]) -> some View {
        DisclosureGroup("History & Statutory Notes (\(notes.count))", isExpanded: $showOfficialNotes) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, noteNode in
                    Text(noteNode.normalizedText)
                        .font(.system(size: max(12, readerFontSize - 2)))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Async Off-Main-Thread Section Load + Flat Block Compilation

    private func loadSectionAsync(sectionID: String, initialAnchor: String?) async {
        highlightedAnchor = initialAnchor
        let db = corpus.database
        let loaded = await Task.detached(priority: .userInitiated) { () -> (
            SectionRecord?,
            [RenderedProvisionBlock],
            (previous: SectionSummary?, next: SectionSummary?),
            [SectionSummary],
            SectionSummary?
        ) in
            guard let rec = db.sectionRecord(forID: sectionID) else {
                return (nil, [], (nil, nil), [], nil)
            }
            let blocks = ProvisionBlockCompiler.compile(
                sectionID: rec.summary.id,
                provision: rec.provision,
                corpus: rec.summary.corpus
            )
            let adj = db.adjacentSections(around: rec.summary)
            if rec.summary.corpus == .irc {
                let regs = db.relatedRegulations(forIRCSection: rec.summary.number)
                return (rec, blocks, adj, regs, nil)
            } else {
                let parent = rec.summary.parentIRC.flatMap {
                    db.resolve(CitationTarget(corpus: .irc, sectionNumber: $0))
                }
                return (rec, blocks, adj, [], parent)
            }
        }.value

        guard !Task.isCancelled else { return }
        record = loaded.0
        compiledBlocks = loaded.1
        adjacent = loaded.2
        relatedRegs = loaded.3
        parentIRC = loaded.4
    }

    private func scrollToRouteAnchor(proxy: ScrollViewProxy) {
        guard let anchor = route.anchor, !anchor.isEmpty else { return }
        highlightedAnchor = anchor
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            proxy.scrollTo("anchor:\(anchor)", anchor: .top)
        }
    }

    private func handleCitationURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "taxlaw" else { return .systemAction }
        let raw = url.absoluteString
            .replacingOccurrences(of: "taxlaw://cite/", with: "")
            .removingPercentEncoding ?? ""
        if let target = CitationResolver.parse(raw) {
            openTarget(target, disposition: .currentPane)
        }
        return .handled
    }

    private func openTarget(_ target: CitationTarget, disposition: OpenDisposition) {
        if disposition == .currentPane, let matched = corpus.database.resolve(target) {
            onNavigate(ProvisionRoute(sectionID: matched.id, anchor: target.subsectionAnchor))
        } else if let onOpenCitation {
            onOpenCitation(target, disposition)
        } else if let matched = corpus.database.resolve(target) {
            openWindow(value: ProvisionRoute(sectionID: matched.id, anchor: target.subsectionAnchor))
        }
    }
}
