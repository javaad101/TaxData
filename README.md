# TaxData & TaxCodeReader

Offline macOS & iOS reader and search engine for the **Internal Revenue Code (Title 26 U.S.C.)** and **Treasury Regulations (26 C.F.R.)**.

## Project Layout

```text
TaxData/
├── Data/                                         # Raw XML corpora & course documents
│   ├── title26.xml                               # 26 U.S.C. (Internal Revenue Code, USLM XML)
│   ├── ECFR-title26.xml                          # 26 C.F.R. (Treasury Regulations, eCFR XML)
│   └── Course Materials Results | Northwestern University.pdf
│
├── Sources/TaxData/                              # Swift Package: core parsing, citations & SQLite FTS5
│   ├── Models/
│   │   ├── DocumentNode.swift                    # Schema-agnostic lossless XML/JSON tree & streamer
│   │   ├── Provision.swift                       # Unified statutory/regulatory wrapper over DocumentNode
│   │   ├── LegalCorpus.swift                     # In-memory O(1) corpus index
│   │   └── SectionModels.swift                   # SectionSummary, SectionRecord, SearchHit & study types
│   ├── Citations/
│   │   └── CitationResolver.swift                # Parses "162(a)(2)", "1.141-1" & inline prose citations
│   ├── Database/
│   │   ├── SQLiteStore.swift                     # SQLite3 connection, schema migrations & C bindings
│   │   ├── TaxDatabase.swift                     # Citation lookup, hierarchy queries & FTS5 BM25 search
│   │   ├── TaxDatabase+Import.swift              # XML -> SQLite + FTS5 ingestion pipeline
│   │   └── TaxDatabase+Study.swift               # Course Pinboards, bookmarks, exam notes & history
│   └── Downloads/
│       └── CFRDownloader.swift                   # Local bootstrap discovery & optional GPO volume fetcher
│
└── TaxCodeApp/                                   # Native SwiftUI App (macOS & iOS)
    ├── TaxCodeApp.xcodeproj
    └── Sources/
        ├── App/
        │   ├── TaxCodeApp.swift                  # @main Scene, shortcuts & multi-window setup
        │   ├── AppModel.swift                    # @Observable state (tabs, split pane, search, study lists)
        │   └── WorkspaceView.swift               # Main NavigationSplitView, tab bar & split-pane layout
        ├── Sidebar/
        │   ├── SearchSidebarPanel.swift          # Instant citation jump & FTS5 search results
        │   ├── BrowseSidebarPanel.swift          # Title 26 IRC & 26 CFR hierarchical outline
        │   ├── BookmarksSidebarPanel.swift       # Course Pinboards & annotated sections
        │   └── HistorySidebarPanel.swift         # Chronological browsing history
        ├── Reader/
        │   ├── ProvisionReaderView.swift         # Header, IRC<->Reg cross-links, subsection jump bar & notes
        │   ├── ProvisionBodyView.swift           # Recursive USLM/CFR structural tree view
        │   ├── InteractiveLegalText.swift        # Styled legal prose with clickable cross-references
        │   ├── StatutoryTableView.swift          # USLM XHTML, eCFR TABLE & GPOTABLE grid view
        │   └── PopOutProvisionWindow.swift       # Standalone pop-out reader window
        └── Integrations/
            ├── VolumeManagerSheet.swift          # Local XML import & optional GPO volume downloader UI
            └── SpotlightAndIntents.swift         # CoreSpotlight indexing & Siri / AppIntents
```

## How Data Flows

1. **Bootstrap / Import (`TaxDatabase+Import.swift` & `CFRDownloader.swift`)**: On first launch, `AppModel.bootstrapIfNeeded()` discovers XML files in `Data/` (`title26.xml` and `ECFR-title26.xml`), parses them via `DocumentNode`, and indexes every section into `~/Library/Application Support/TaxCodeReader/taxlaw.sqlite` with an FTS5 full-text index.
2. **Lookup & Search (`CitationResolver.swift` & `TaxDatabase.swift`)**: Queries in the sidebar check `CitationResolver.parse(...)` first for instant jumps (e.g., `704(b)` or `1.704-1(b)(2)`), then fall back to BM25-ranked SQLite FTS5 search.
3. **Reading (`Reader/`)**: Selecting a section decodes its lossless `DocumentNode` JSON blob from SQLite into a `Provision` and renders subsections, tables, inline cross-reference links, and related IRC/Regulation strips.

## Building & Running

- **App (Xcode):** Open `TaxCodeApp/TaxCodeApp.xcodeproj` and press **⌘R** (`TaxCodeReader` target).
- **Library CLI check:** Run `swift build` from the repository root.
