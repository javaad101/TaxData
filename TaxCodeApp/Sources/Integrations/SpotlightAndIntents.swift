import AppIntents
import CoreSpotlight
import Foundation
import TaxData
import UniformTypeIdentifiers

// MARK: - IndexedEntity (Spotlight + Siri + Apple Intelligence)

public struct ProvisionEntity: IndexedEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Tax Provision",
        numericFormat: "\(placeholder: .int) tax provisions"
    )

    public static let defaultQuery = ProvisionEntityQuery()

    public let id: String

    @Property(title: "Citation")
    public var citation: String

    @Property(title: "Section Number")
    public var sectionNumber: String

    @Property(title: "Heading")
    public var heading: String

    @Property(title: "Source")
    public var corpusName: String

    @Property(title: "Location")
    public var breadcrumb: String

    @Property(title: "Text Excerpt")
    public var excerpt: String

    public init(summary: SectionSummary) {
        self.id = summary.id
        self.citation = summary.displayTitle
        self.sectionNumber = summary.number
        self.heading = summary.heading
        self.corpusName = summary.corpus == .irc ? "Internal Revenue Code" : "Treasury Regulations"
        self.breadcrumb = summary.breadcrumb
        self.excerpt = summary.previewText
    }

    public var displayRepresentation: DisplayRepresentation {
        let titleText = heading.isEmpty ? citation : "\(citation) — \(heading)"
        let subText = breadcrumb.isEmpty ? corpusName : breadcrumb
        let symbol = corpusName == "Internal Revenue Code" ? "building.columns.fill" : "book.closed.fill"
        return DisplayRepresentation(
            title: "\(titleText)",
            subtitle: "\(subText)",
            image: .init(systemName: symbol)
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attrs = defaultAttributeSet
        let fullTitle = heading.isEmpty ? citation : "\(citation) — \(heading)"
        attrs.title = fullTitle
        attrs.displayName = citation
        attrs.contentDescription = breadcrumb.isEmpty ? excerpt : "\(breadcrumb)\n\(excerpt)"
        attrs.keywords = Self.makeKeywords(
            citation: citation,
            number: sectionNumber,
            heading: heading,
            isIRC: corpusName == "Internal Revenue Code"
        )
        return attrs
    }

    internal static func makeKeywords(
        citation: String,
        number: String,
        heading: String,
        isIRC: Bool
    ) -> [String] {
        var keys: [String] = [citation, number, "§ \(number)", "Section \(number)"]
        if !heading.isEmpty {
            keys.append(heading)
        }
        if isIRC {
            keys.append(contentsOf: ["IRC \(number)", "I.R.C. \(number)", "26 USC \(number)", "Internal Revenue Code", "Tax Code"])
        } else {
            keys.append(contentsOf: ["Reg \(number)", "Treas. Reg. \(number)", "26 CFR \(number)", "Treasury Regulations"])
        }
        return keys
    }
}

// MARK: - Entity Query & System Reindexing

public struct ProvisionEntityQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [ProvisionEntity.ID]) async throws -> [ProvisionEntity] {
        TaxDatabase.shared.summaries(forIDs: identifiers).map(ProvisionEntity.init(summary:))
    }

    public func entities(matching string: String) async throws -> [ProvisionEntity] {
        TaxDatabase.shared.search(string, scope: .all, limit: 25)
            .map { ProvisionEntity(summary: $0.summary) }
    }

    public func suggestedEntities() async throws -> [ProvisionEntity] {
        let recent = TaxDatabase.shared.recentHistory(limit: 12).map(\.summary)
        if !recent.isEmpty {
            return recent.map(ProvisionEntity.init(summary:))
        }
        return Array(TaxDatabase.shared.allSectionSummaries().prefix(12)).map(ProvisionEntity.init(summary:))
    }
}

@available(macOS 27.0, iOS 27.0, *)
extension ProvisionEntityQuery: IndexedEntityQuery {
    public func reindexEntities(
        for identifiers: [ProvisionEntity.ID],
        indexDescription: CSSearchableIndexDescription
    ) async throws {
        let entities = TaxDatabase.shared.summaries(forIDs: identifiers).map(ProvisionEntity.init(summary:))
        if !entities.isEmpty {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }

    public func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        _ = await SpotlightIndexer.indexSummaries(database: .shared, sourceID: nil)
    }
}

// MARK: - CoreSpotlight Batch Indexer

public enum SpotlightIndexer {
    @discardableResult
    public static func indexSummaries(
        database: TaxDatabase = .shared,
        sourceID: String? = nil
    ) async -> Int {
        let summaries = await Task.detached(priority: .utility) {
            database.allSectionSummaries(sourceID: sourceID)
        }.value
        guard !summaries.isEmpty else { return 0 }

        let index = CSSearchableIndex.default()
        let batchSize = 400
        var offset = 0

        while offset < summaries.count {
            let end = min(offset + batchSize, summaries.count)
            let slice = Array(summaries[offset..<end])
            let entities = slice.map(ProvisionEntity.init(summary:))

            try? await index.indexAppEntities(entities)

            let items: [CSSearchableItem] = slice.map { summary in
                let attrs = CSSearchableItemAttributeSet(contentType: .text)
                let fullTitle = summary.heading.isEmpty
                    ? summary.displayTitle
                    : "\(summary.displayTitle) — \(summary.heading)"
                attrs.title = fullTitle
                attrs.displayName = summary.displayTitle
                attrs.contentDescription = summary.breadcrumb.isEmpty
                    ? summary.previewText
                    : "\(summary.breadcrumb)\n\(summary.previewText)"
                attrs.keywords = ProvisionEntity.makeKeywords(
                    citation: summary.displayTitle,
                    number: summary.number,
                    heading: summary.heading,
                    isIRC: summary.corpus == .irc
                )
                return CSSearchableItem(
                    uniqueIdentifier: summary.id,
                    domainIdentifier: "com.taxdata.reader.\(summary.corpus.rawValue.lowercased())",
                    attributeSet: attrs
                )
            }
            try? await index.indexSearchableItems(items)

            offset = end
        }
        return summaries.count
    }
}

// MARK: - Siri, Shortcuts & Apple Intelligence Intents

public struct OpenProvisionIntent: OpenIntent {
    public static let title: LocalizedStringResource = "Open Tax Provision"
    public static let description = IntentDescription("Opens an Internal Revenue Code or Treasury Regulation section in Tax Code Reader.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Provision")
    public var target: ProvisionEntity

    public init() {}

    public init(target: ProvisionEntity) {
        self.target = target
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        NavigationBridge.shared.open(ProvisionRoute(sectionID: target.id))
        return .result()
    }
}

public struct LookupCitationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Look Up Tax Citation"
    public static let description = IntentDescription(
        "Reads an exact IRC or Treasury Regulation citation (such as 162(a)(2), 351(a), 704(b), or 1.141-1) for Siri and Apple Intelligence."
    )

    @Parameter(
        title: "Citation",
        description: "Section or subsection citation, e.g. '162(a)(2)', '704(b)', or '1.141-1'",
        requestValueDialog: IntentDialog("Which IRC or Treasury Regulation citation would you like to look up?")
    )
    public var citation: String

    @Parameter(title: "Open in Reader", default: false)
    public var openInApp: Bool

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<ProvisionEntity?> & ProvidesDialog {
        let db = TaxDatabase.shared

        if let parsed = CitationResolver.parse(citation),
           let summary = db.resolve(parsed),
           let record = db.sectionRecord(forID: summary.id) {
            var targetProvision = record.provision
            var matchedSubPath: [String] = []
            for sub in parsed.subsections {
                if let child = targetProvision[sub] {
                    targetProvision = child
                    matchedSubPath.append(sub)
                } else {
                    break
                }
            }

            let subSuffix = matchedSubPath.map { "(\($0))" }.joined()
            let header = "\(summary.displayTitle)\(subSuffix) — \(summary.heading)"
            let rawBody = targetProvision.bodyText
            let clippedBody = rawBody.count > 1_100
                ? String(rawBody.prefix(1_100)) + "…"
                : rawBody

            if openInApp {
                await MainActor.run {
                    NavigationBridge.shared.open(
                        ProvisionRoute(sectionID: summary.id, anchor: parsed.subsectionAnchor)
                    )
                }
            }

            let entity = ProvisionEntity(summary: summary)
            return .result(
                value: entity,
                dialog: IntentDialog(stringLiteral: "\(header)\n\n\(clippedBody)")
            )
        }

        if let topHit = db.search(citation, scope: .all, limit: 1).first {
            let entity = ProvisionEntity(summary: topHit.summary)
            let msg = "\(topHit.summary.displayTitle) — \(topHit.summary.heading)\n\n\(topHit.summary.previewText)"
            return .result(value: entity, dialog: IntentDialog(stringLiteral: msg))
        }

        return .result(
            value: nil,
            dialog: IntentDialog(stringLiteral: "No matching IRC or Treasury Regulation section was found for '\(citation)'.")
        )
    }
}

public struct SearchTaxLawIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search Tax Code & Regulations"
    public static let description = IntentDescription(
        "Searches the offline Internal Revenue Code and Treasury Regulations database using full-text BM25 ranking."
    )

    @Parameter(
        title: "Search Query",
        requestValueDialog: IntentDialog("What tax term, phrase, or topic should I search for?")
    )
    public var query: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[ProvisionEntity]> & ProvidesDialog {
        let hits = TaxDatabase.shared.search(query, scope: .all, limit: 8)
        let entities = hits.map { ProvisionEntity(summary: $0.summary) }

        guard !entities.isEmpty else {
            return .result(
                value: [],
                dialog: IntentDialog(stringLiteral: "No provisions matched '\(query)'.")
            )
        }

        let summaryLines = hits.prefix(5).map { hit in
            "• \(hit.summary.displayTitle): \(hit.summary.heading)"
        }.joined(separator: "\n")

        return .result(
            value: entities,
            dialog: IntentDialog(stringLiteral: "Top matches for '\(query)':\n\(summaryLines)")
        )
    }
}

public struct TaxLawShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LookupCitationIntent(),
            phrases: [
                "Look up citation in \(.applicationName)",
                "Read tax section in \(.applicationName)",
                "Check Internal Revenue Code in \(.applicationName)",
            ],
            shortTitle: "Look Up Citation",
            systemImageName: "building.columns.fill"
        )
        AppShortcut(
            intent: SearchTaxLawIntent(),
            phrases: [
                "Search tax law in \(.applicationName)",
                "Search Treasury Regulations in \(.applicationName)",
                "Find tax code provisions in \(.applicationName)",
            ],
            shortTitle: "Search Tax Law",
            systemImageName: "magnifyingglass"
        )
    }
}
