import Foundation
import Observation
import SwiftUI
import TaxData

public enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case search = "Search"
    case reader = "Reader"
    case entities = "Entities"
    case assets = "Assets"
    case todos = "To-Do"
    case dayCount = "Day Count"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .reader: return "doc.text"
        case .entities: return "building.2"
        case .assets: return "cube.box"
        case .todos: return "checklist"
        case .dayCount: return "calendar"
        }
    }
}

@MainActor
@Observable
public final class WindowUIState {
    public let id = UUID()
    public var activePane: WorkspaceSection = .search
    public var searchQuery: String = ""
    public var searchScope: SearchScope = .all
    public var searchHits: [SearchHit] = []
    public var searchFocusRequestToken: Int = 0
    public var selectedEntityID: UUID? = nil
    public var selectedAssetID: UUID? = nil

    public init() {}

    public func requestSearchFocus() {
        activePane = .search
        searchFocusRequestToken &+= 1
    }

    public func updateSearch(using database: TaxDatabase) {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchHits = []
            return
        }
        searchHits = database.search(trimmed, scope: searchScope, limit: 100)
    }
}

public struct FocusedWindowActions {
    public var focusSearch: @MainActor () -> Void
    public var newEntity: @MainActor () -> Void
    public var newAsset: @MainActor () -> Void
    public var openTodos: @MainActor () -> Void
    public var openDayCount: @MainActor () -> Void
    public var newTab: @MainActor () -> Void
    public var toggleSplitPane: @MainActor () -> Void
    public var goBack: @MainActor () -> Void
    public var goForward: @MainActor () -> Void
    public var canNewTab: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
}

public extension FocusedValues {
    @Entry var focusedWindowActions: FocusedWindowActions? = nil
}
