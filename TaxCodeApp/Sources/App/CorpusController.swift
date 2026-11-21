import Foundation
import Observation
import TaxData

/// Bridges `OpenProvisionIntent` and Spotlight activations into the active document window.
@MainActor
public final class NavigationBridge {
    public static let shared = NavigationBridge()
    public var onOpenRoute: ((ProvisionRoute) -> Void)?
    public var pendingRoute: ProvisionRoute?

    public func open(_ route: ProvisionRoute) {
        if let onOpenRoute {
            onOpenRoute(route)
        } else {
            pendingRoute = route
        }
    }
}

/// Shared, read-only corpus coordinator shared across all open `DocumentGroup` workflow windows.
/// Manages the SQLite + FTS5 index, XML volume imports, hierarchy outlines, and Spotlight indexing.
@MainActor
@Observable
public final class CorpusController {
    public let database: TaxDatabase
    public let ingestor: CorpusIngestor

    public var importedSources: [ImportedSourceInfo] = []
    public var ircGroups: [HierarchyGroup] = []
    public var cfrGroups: [HierarchyGroup] = []

    public var isBootstrapping: Bool = false
    public var statusBanner: String?
    public var isShowingVolumeManager: Bool = false
    public var spotlightIndexedCount: Int = 0
    public var isIndexingSpotlight: Bool = false

    private var hasBootstrapped = false

    public init(database: TaxDatabase = .shared) {
        self.database = database
        self.ingestor = CorpusIngestor(database: database)
        refreshMetadata()
    }

    public func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        if database.totalSectionCount() == 0 {
            let discovered = CorpusIngestor.discoverBootstrapXMLFiles()
            if !discovered.isEmpty {
                isBootstrapping = true
                statusBanner = "Indexing local XML files into offline FTS5 database…"
                let db = database
                await Task.detached(priority: .userInitiated) {
                    for url in discovered {
                        _ = try? db.importXMLFile(at: url)
                    }
                }.value
                isBootstrapping = false
                statusBanner = nil
                refreshMetadata()
                await reindexSpotlight()
            }
        } else {
            let total = database.totalSectionCount()
            spotlightIndexedCount = total
            let lastSynced = UserDefaults.standard.integer(forKey: "lastSpotlightSyncedCount")
            if lastSynced != total {
                Task {
                    await reindexSpotlight()
                    UserDefaults.standard.set(total, forKey: "lastSpotlightSyncedCount")
                }
            }
        }
    }

    public func refreshMetadata() {
        importedSources = database.importedSources()
        ircGroups = database.hierarchyGroups(for: .irc)
        cfrGroups = database.hierarchyGroups(for: .cfr)
    }

    public func title(forSectionID sectionID: String) -> String {
        database.summary(forID: sectionID)?.displayTitle ?? "Provision"
    }

    /// Resolves the natural side-by-side companion route for a given route (first regulation for an IRC section,
    /// or parent IRC statute for a Treasury Regulation).
    public func defaultCompanionRoute(for route: ProvisionRoute) -> ProvisionRoute {
        if let summary = database.summary(forID: route.sectionID) {
            if summary.corpus == .irc,
               let firstReg = database.relatedRegulations(forIRCSection: summary.number).first {
                return ProvisionRoute(sectionID: firstReg.id)
            } else if summary.corpus == .cfr,
                      let parentNum = summary.parentIRC,
                      let parentSec = database.resolve(CitationTarget(corpus: .irc, sectionNumber: parentNum)) {
                return ProvisionRoute(sectionID: parentSec.id)
            }
        }
        return route
    }

    public func reindexSpotlight(sourceID: String? = nil) async {
        isIndexingSpotlight = true
        defer { isIndexingSpotlight = false }
        let count = await SpotlightIndexer.indexSummaries(
            database: database,
            sourceID: sourceID
        )
        spotlightIndexedCount = database.totalSectionCount()
        UserDefaults.standard.set(spotlightIndexedCount, forKey: "lastSpotlightSyncedCount")
        if count > 0 {
            statusBanner = "Indexed \(spotlightIndexedCount) sections for Spotlight, Siri & Apple Intelligence."
        }
    }
}
