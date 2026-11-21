import Foundation
import SwiftUI
import TaxData
import UniformTypeIdentifiers

extension UTType {
    public static var taxWorkflowDocument: UTType {
        UTType(exportedAs: "com.taxdata.workflow", conformingTo: .json)
    }
}

public enum OpenDisposition: Sendable {
    case currentPane
    case newTab
    case splitPane
}

public struct ProvisionRoute: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(sectionID)#\(anchor ?? "")" }
    public var sectionID: String
    public var anchor: String?

    public init(sectionID: String, anchor: String? = nil) {
        self.sectionID = sectionID
        self.anchor = anchor
    }
}

public struct ReaderTab: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var route: ProvisionRoute
    public var title: String
    public var backStack: [ProvisionRoute] = []
    public var forwardStack: [ProvisionRoute] = []

    public init(id: UUID = UUID(), route: ProvisionRoute, title: String) {
        self.id = id
        self.route = route
        self.title = title
    }
}

public struct SplitPaneState: Codable, Hashable, Sendable {
    public var route: ProvisionRoute
    public var backStack: [ProvisionRoute] = []
    public var forwardStack: [ProvisionRoute] = []

    public init(route: ProvisionRoute, backStack: [ProvisionRoute] = [], forwardStack: [ProvisionRoute] = []) {
        self.route = route
        self.backStack = backStack
        self.forwardStack = forwardStack
    }
}

public struct PinnedProvision: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(route.sectionID)|\(route.anchor ?? "")" }
    public var route: ProvisionRoute
    public var pinnedAt: Date

    public init(route: ProvisionRoute, pinnedAt: Date = Date()) {
        self.route = route
        self.pinnedAt = pinnedAt
    }
}

public struct WorkflowHistoryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var route: ProvisionRoute
    public var visitedAt: Date

    public init(id: UUID = UUID(), route: ProvisionRoute, visitedAt: Date = Date()) {
        self.id = id
        self.route = route
        self.visitedAt = visitedAt
    }
}

// MARK: - Core Primitives (To-Do, Day Count, Entity, Asset)

public struct TodoItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var isCompleted: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, isCompleted: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}

public enum TaxClassification: String, Codable, CaseIterable, Identifiable, Sendable {
    case disregarded = "Disregarded Entity"
    case partnership = "Partnership"
    case cCorp = "C Corporation"
    case sCorp = "S Corporation"
    case foreignCorp = "Foreign Corporation"
    case trust = "Trust"
    case taxExempt = "Tax-Exempt"

    public var id: String { rawValue }
}

public struct EntityPrimitive: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var jurisdiction: String
    public var legalForm: String
    public var classification: TaxClassification
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String = "Untitled Entity",
        jurisdiction: String = "DE",
        legalForm: String = "LLC",
        classification: TaxClassification = .disregarded,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.jurisdiction = jurisdiction
        self.legalForm = legalForm
        self.classification = classification
        self.notes = notes
    }
}

public enum AssetCharacter: String, Codable, CaseIterable, Identifiable, Sendable {
    case capital = "Capital (§ 1221)"
    case section1231 = "§ 1231 Property"
    case ordinary = "Ordinary / Inventory"
    case intangible = "Intangible / IP (§ 197)"
    case equity = "Stock / Partnership Interest"
    case cash = "Cash / Debt"

    public var id: String { rawValue }
}

public struct AssetPrimitive: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var character: AssetCharacter
    public var adjustedBasis: String
    public var fairMarketValue: String
    public var acquisitionDate: Date?
    public var ownerEntityID: UUID?
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String = "Untitled Asset",
        character: AssetCharacter = .capital,
        adjustedBasis: String = "",
        fairMarketValue: String = "",
        acquisitionDate: Date? = nil,
        ownerEntityID: UUID? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.character = character
        self.adjustedBasis = adjustedBasis
        self.fairMarketValue = fairMarketValue
        self.acquisitionDate = acquisitionDate
        self.ownerEntityID = ownerEntityID
        self.notes = notes
    }
}

public struct DayCountState: Codable, Hashable, Sendable {
    public var startDate: Date
    public var endDate: Date
    public var includeStartDate: Bool
    public var includeEndDate: Bool
    public var anchorDate: Date
    public var offsetDays: Int
    public var currentYearDays: Int
    public var priorYear1Days: Int
    public var priorYear2Days: Int

    public init(
        startDate: Date = Calendar.current.startOfDay(for: Date()),
        endDate: Date = Calendar.current.startOfDay(for: Date()),
        includeStartDate: Bool = false,
        includeEndDate: Bool = true,
        anchorDate: Date = Calendar.current.startOfDay(for: Date()),
        offsetDays: Int = 180,
        currentYearDays: Int = 0,
        priorYear1Days: Int = 0,
        priorYear2Days: Int = 0
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.includeStartDate = includeStartDate
        self.includeEndDate = includeEndDate
        self.anchorDate = anchorDate
        self.offsetDays = offsetDays
        self.currentYearDays = currentYearDays
        self.priorYear1Days = priorYear1Days
        self.priorYear2Days = priorYear2Days
    }
}

// MARK: - Document Model

public struct TaxWorkflowDocument: FileDocument, Codable, Equatable, Sendable {
    public static var readableContentTypes: [UTType] { [.taxWorkflowDocument, .json] }
    public static var writableContentTypes: [UTType] { [.taxWorkflowDocument] }

    public var schemaVersion: Int = 3
    public var workflowSummary: String = ""
    public var workspaceMemo: AttributedString = AttributedString()
    public var tabs: [ReaderTab] = []
    public var activeTabID: UUID? = nil
    public var splitPane: SplitPaneState? = nil
    public var pinnedProvisions: [PinnedProvision] = []
    public var sectionNotes: [String: AttributedString] = [:]
    public var blockEdits: [String: AttributedString] = [:]
    public var history: [WorkflowHistoryItem] = []

    public var todos: [TodoItem] = []
    public var entities: [EntityPrimitive] = []
    public var assets: [AssetPrimitive] = []
    public var dayCount: DayCountState = DayCountState()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workflowSummary, workspaceMemo, tabs, activeTabID, splitPane
        case pinnedProvisions, sectionNotes, blockEdits, history, todos, entities, assets, dayCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 3
        self.workflowSummary = try c.decodeIfPresent(String.self, forKey: .workflowSummary) ?? ""
        self.workspaceMemo = try c.decodeIfPresent(AttributedString.self, forKey: .workspaceMemo) ?? AttributedString()
        self.tabs = try c.decodeIfPresent([ReaderTab].self, forKey: .tabs) ?? []
        self.activeTabID = try c.decodeIfPresent(UUID.self, forKey: .activeTabID)
        self.splitPane = try c.decodeIfPresent(SplitPaneState.self, forKey: .splitPane)
        self.pinnedProvisions = try c.decodeIfPresent([PinnedProvision].self, forKey: .pinnedProvisions) ?? []
        self.sectionNotes = try c.decodeIfPresent([String: AttributedString].self, forKey: .sectionNotes) ?? [:]
        self.blockEdits = try c.decodeIfPresent([String: AttributedString].self, forKey: .blockEdits) ?? [:]
        self.history = try c.decodeIfPresent([WorkflowHistoryItem].self, forKey: .history) ?? []
        self.todos = try c.decodeIfPresent([TodoItem].self, forKey: .todos) ?? []
        self.entities = try c.decodeIfPresent([EntityPrimitive].self, forKey: .entities) ?? []
        self.assets = try c.decodeIfPresent([AssetPrimitive].self, forKey: .assets) ?? []
        self.dayCount = try c.decodeIfPresent(DayCountState.self, forKey: .dayCount) ?? DayCountState()
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(TaxWorkflowDocument.self, from: data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return FileWrapper(regularFileWithContents: data)
    }

    // MARK: - Derived Tab State

    public var activeTabIndex: Int? {
        guard let activeTabID else { return tabs.indices.first }
        return tabs.firstIndex { $0.id == activeTabID }
    }

    public var activeTab: ReaderTab? {
        guard let idx = activeTabIndex, tabs.indices.contains(idx) else { return nil }
        return tabs[idx]
    }

    // MARK: - Navigation Mutations

    public mutating func open(_ route: ProvisionRoute, title: String, inNewTab: Bool = false) {
        recordVisit(route)

        if inNewTab || tabs.isEmpty || activeTabIndex == nil {
            let tab = ReaderTab(route: route, title: title)
            tabs.append(tab)
            activeTabID = tab.id
        } else if let idx = activeTabIndex {
            let current = tabs[idx].route
            if current != route {
                tabs[idx].backStack.append(current)
                tabs[idx].forwardStack.removeAll()
                tabs[idx].route = route
                tabs[idx].title = title
            }
        }
    }

    public mutating func openInSplitPane(_ route: ProvisionRoute) {
        recordVisit(route)

        if var existing = splitPane {
            if existing.route != route {
                existing.backStack.append(existing.route)
                existing.forwardStack.removeAll()
                existing.route = route
                splitPane = existing
            }
        } else {
            splitPane = SplitPaneState(route: route)
        }
    }

    public mutating func closeSplitPane() {
        splitPane = nil
    }

    public mutating func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeTabID == id {
            if tabs.indices.contains(idx) {
                activeTabID = tabs[idx].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
    }

    public mutating func goBackInActiveTab(titleResolver: (String) -> String) {
        guard let idx = activeTabIndex, let prev = tabs[idx].backStack.popLast() else { return }
        let current = tabs[idx].route
        tabs[idx].forwardStack.append(current)
        tabs[idx].route = prev
        tabs[idx].title = titleResolver(prev.sectionID)
    }

    public mutating func goForwardInActiveTab(titleResolver: (String) -> String) {
        guard let idx = activeTabIndex, let next = tabs[idx].forwardStack.popLast() else { return }
        let current = tabs[idx].route
        tabs[idx].backStack.append(current)
        tabs[idx].route = next
        tabs[idx].title = titleResolver(next.sectionID)
    }

    public mutating func goBackInSplitPane() {
        guard var split = splitPane, let prev = split.backStack.popLast() else { return }
        split.forwardStack.append(split.route)
        split.route = prev
        splitPane = split
    }

    public mutating func goForwardInSplitPane() {
        guard var split = splitPane, let next = split.forwardStack.popLast() else { return }
        split.backStack.append(split.route)
        split.route = next
        splitPane = split
    }

    // MARK: - Pins, Section Notes & Block Text Edits (Line Breaks / Diagramming)

    public func isPinned(_ route: ProvisionRoute) -> Bool {
        pinnedProvisions.contains { $0.route == route || ($0.route.sectionID == route.sectionID && route.anchor == nil && $0.route.anchor == nil) }
    }

    public func hasAnyPin(forSectionID sectionID: String) -> Bool {
        pinnedProvisions.contains { $0.route.sectionID == sectionID }
    }

    public mutating func togglePin(_ route: ProvisionRoute) {
        if let idx = pinnedProvisions.firstIndex(where: { $0.route == route }) {
            pinnedProvisions.remove(at: idx)
        } else {
            pinnedProvisions.insert(PinnedProvision(route: route), at: 0)
        }
    }

    public func note(for sectionID: String) -> AttributedString {
        sectionNotes[sectionID] ?? AttributedString()
    }

    public mutating func setNote(_ value: AttributedString, for sectionID: String) {
        let trimmedPlain = String(value.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPlain.isEmpty {
            sectionNotes.removeValue(forKey: sectionID)
        } else {
            sectionNotes[sectionID] = value
        }
    }

    public func blockText(storageKey: String, defaultText: AttributedString) -> AttributedString {
        blockEdits[storageKey] ?? defaultText
    }

    public mutating func setBlockText(_ newValue: AttributedString, storageKey: String, defaultText: AttributedString) {
        var cleaned = newValue
        cleaned.font = nil
        if String(cleaned.characters) == String(defaultText.characters) {
            blockEdits.removeValue(forKey: storageKey)
        } else {
            blockEdits[storageKey] = cleaned
        }
    }

    public mutating func resetBlockEdits(forSectionID sectionID: String) {
        let prefix = "\(sectionID)#"
        for key in blockEdits.keys where key.hasPrefix(prefix) {
            blockEdits.removeValue(forKey: key)
        }
    }

    public func hasBlockEdits(forSectionID sectionID: String) -> Bool {
        let prefix = "\(sectionID)#"
        return blockEdits.keys.contains { $0.hasPrefix(prefix) }
    }

    public mutating func recordVisit(_ route: ProvisionRoute) {
        let now = Date()
        if let latest = history.first, latest.route == route {
            history[0].visitedAt = now
            return
        }
        history.insert(WorkflowHistoryItem(route: route, visitedAt: now), at: 0)
        if history.count > 250 {
            history.removeLast(history.count - 250)
        }
    }
}
