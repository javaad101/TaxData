import Foundation

// MARK: - Section & Search Models

/// Lightweight metadata for a section used in lists, search results, Spotlight, and Siri intents
/// without materializing the full XML subtree in memory.
public struct SectionSummary: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var sourceID: String
    public var corpus: CitationTarget.CorpusKind
    public var number: String
    public var displayTitle: String
    public var heading: String
    public var breadcrumb: String
    public var parentIRC: String?
    public var previewText: String
    public var sortOrder: Int

    public init(
        id: String,
        sourceID: String,
        corpus: CitationTarget.CorpusKind,
        number: String,
        displayTitle: String,
        heading: String,
        breadcrumb: String,
        parentIRC: String?,
        previewText: String,
        sortOrder: Int
    ) {
        self.id = id
        self.sourceID = sourceID
        self.corpus = corpus
        self.number = number
        self.displayTitle = displayTitle
        self.heading = heading
        self.breadcrumb = breadcrumb
        self.parentIRC = parentIRC
        self.previewText = previewText
        self.sortOrder = sortOrder
    }
}

/// Full section payload including its decoded lossless `Provision` tree.
public struct SectionRecord: Sendable, Hashable {
    public var summary: SectionSummary
    public var bodyText: String
    public var provision: Provision

    public init(summary: SectionSummary, bodyText: String, provision: Provision) {
        self.summary = summary
        self.bodyText = bodyText
        self.provision = provision
    }
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public var id: String { summary.id }
    public var summary: SectionSummary
    public var snippet: String
    public var targetAnchor: String?
    public var isExactCitationMatch: Bool

    public init(
        summary: SectionSummary,
        snippet: String,
        targetAnchor: String?,
        isExactCitationMatch: Bool
    ) {
        self.summary = summary
        self.snippet = snippet
        self.targetAnchor = targetAnchor
        self.isExactCitationMatch = isExactCitationMatch
    }
}

public enum SearchScope: String, Sendable, CaseIterable, Identifiable {
    case all = "All"
    case irc = "IRC"
    case cfr = "Regs"

    public var id: String { rawValue }
}

public struct ImportedSourceInfo: Sendable, Hashable, Identifiable {
    public var id: String { sourceID }
    public var sourceID: String
    public var corpus: CitationTarget.CorpusKind
    public var title: String
    public var filePath: String?
    public var importedAt: Date
    public var sectionCount: Int

    public init(
        sourceID: String,
        corpus: CitationTarget.CorpusKind,
        title: String,
        filePath: String?,
        importedAt: Date,
        sectionCount: Int
    ) {
        self.sourceID = sourceID
        self.corpus = corpus
        self.title = title
        self.filePath = filePath
        self.importedAt = importedAt
        self.sectionCount = sectionCount
    }
}

public struct HierarchyGroup: Sendable, Hashable, Identifiable {
    public var id: String { "\(corpus.rawValue):\(breadcrumb)" }
    public var corpus: CitationTarget.CorpusKind
    public var breadcrumb: String
    public var sections: [SectionSummary]

    public init(corpus: CitationTarget.CorpusKind, breadcrumb: String, sections: [SectionSummary]) {
        self.corpus = corpus
        self.breadcrumb = breadcrumb
        self.sections = sections
    }
}

// MARK: - Study, Pinboard & History Models

public struct BookmarkFolder: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var icon: String
    public var sortOrder: Int

    public init(id: String, name: String, icon: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
    }
}

public struct BookmarkEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(folderID)|\(summary.id)|\(anchor ?? "")" }
    public var folderID: String
    public var summary: SectionSummary
    public var anchor: String?
    public var createdAt: Date

    public init(folderID: String, summary: SectionSummary, anchor: String?, createdAt: Date) {
        self.folderID = folderID
        self.summary = summary
        self.anchor = anchor
        self.createdAt = createdAt
    }
}

public struct AnnotatedSection: Sendable, Hashable, Identifiable {
    public var id: String { summary.id }
    public var summary: SectionSummary
    public var note: String
    public var updatedAt: Date

    public init(summary: SectionSummary, note: String, updatedAt: Date) {
        self.summary = summary
        self.note = note
        self.updatedAt = updatedAt
    }
}

public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var summary: SectionSummary
    public var anchor: String?
    public var visitedAt: Date

    public init(id: Int64, summary: SectionSummary, anchor: String?, visitedAt: Date) {
        self.id = id
        self.summary = summary
        self.anchor = anchor
        self.visitedAt = visitedAt
    }
}
