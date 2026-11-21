import CoreSpotlight
import SwiftUI
import TaxData

public struct WorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @Binding public var document: TaxWorkflowDocument
    @Bindable public var corpus: CorpusController

    @State private var windowUI = WindowUIState()
    @FocusState private var searchFieldFocused: Bool

    public init(document: Binding<TaxWorkflowDocument>, corpus: CorpusController) {
        self._document = document
        self.corpus = corpus
    }

    public var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 260)
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    windowUI.requestSearchFocus()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search (⌘F)")

                Button {
                    createNewEntity()
                } label: {
                    Label("New Entity", systemImage: "plus.rectangle.on.folder")
                }
                .help("New Entity (⇧⌘E)")

                Button {
                    createNewAsset()
                } label: {
                    Label("New Asset", systemImage: "cube.box")
                }
                .help("New Asset (⇧⌘A)")

                Button {
                    windowUI.activePane = .todos
                } label: {
                    Label("To-Do", systemImage: "checklist")
                }
                .help("To-Do (⌘1)")

                Button {
                    windowUI.activePane = .dayCount
                } label: {
                    Label("Days", systemImage: "calendar")
                }
                .help("Day Count (⌘2)")
            }
        }
        .sheet(isPresented: $corpus.isShowingVolumeManager) {
            VolumeManagerSheet(corpus: corpus)
        }
        .focusedSceneValue(\.focusedWindowActions, focusedActions)
        .onChange(of: windowUI.searchFocusRequestToken) { _, _ in
            windowUI.activePane = .search
            searchFieldFocused = true
        }
        .onChange(of: windowUI.searchQuery) { _, _ in
            windowUI.updateSearch(using: corpus.database)
        }
        .onChange(of: windowUI.searchScope) { _, _ in
            windowUI.updateSearch(using: corpus.database)
        }
        .onOpenURL { url in
            guard url.scheme == "taxlaw" else { return }
            let raw = url.absoluteString
                .replacingOccurrences(of: "taxlaw://cite/", with: "")
                .removingPercentEncoding ?? ""
            if let target = CitationResolver.parse(raw) {
                openCitation(target, disposition: .currentPane)
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                openRoute(ProvisionRoute(sectionID: id), inNewTab: false)
            }
        }
        .task {
            NavigationBridge.shared.onOpenRoute = { route in
                openRoute(route, inNewTab: false)
            }
            if let pending = NavigationBridge.shared.pendingRoute {
                NavigationBridge.shared.pendingRoute = nil
                openRoute(pending, inNewTab: false)
            }
            if !document.tabs.isEmpty {
                windowUI.activePane = .reader
            } else {
                searchFieldFocused = true
            }
            await corpus.bootstrapIfNeeded()
        }
    }

    // MARK: - Actions

    private var focusedActions: FocusedWindowActions {
        FocusedWindowActions(
            focusSearch: { windowUI.requestSearchFocus() },
            newEntity: { createNewEntity() },
            newAsset: { createNewAsset() },
            openTodos: { windowUI.activePane = .todos },
            openDayCount: { windowUI.activePane = .dayCount },
            newTab: {
                if let current = document.activeTab?.route {
                    openRoute(current, inNewTab: true)
                }
            },
            toggleSplitPane: { toggleSplitPane() },
            goBack: {
                document.goBackInActiveTab { corpus.title(forSectionID: $0) }
            },
            goForward: {
                document.goForwardInActiveTab { corpus.title(forSectionID: $0) }
            },
            canNewTab: document.activeTab != nil,
            canGoBack: !(document.activeTab?.backStack.isEmpty ?? true),
            canGoForward: !(document.activeTab?.forwardStack.isEmpty ?? true)
        )
    }

    private func createNewEntity() {
        let entity = EntityPrimitive(name: "Entity \(document.entities.count + 1)")
        document.entities.append(entity)
        windowUI.selectedEntityID = entity.id
        windowUI.activePane = .entities
    }

    private func createNewAsset() {
        let asset = AssetPrimitive(name: "Asset \(document.assets.count + 1)")
        document.assets.append(asset)
        windowUI.selectedAssetID = asset.id
        windowUI.activePane = .assets
    }

    public func openRoute(_ route: ProvisionRoute, inNewTab: Bool = false) {
        let title = corpus.title(forSectionID: route.sectionID)
        document.open(route, title: title, inNewTab: inNewTab)
        windowUI.activePane = .reader
    }

    @discardableResult
    public func openCitation(_ target: CitationTarget, disposition: OpenDisposition = .currentPane) -> ProvisionRoute? {
        if let match = corpus.database.resolve(target) {
            let route = ProvisionRoute(sectionID: match.id, anchor: target.subsectionAnchor)
            switch disposition {
            case .currentPane:
                openRoute(route, inNewTab: false)
            case .newTab:
                openRoute(route, inNewTab: true)
            case .splitPane:
                document.openInSplitPane(route)
                windowUI.activePane = .reader
            }
            return route
        } else {
            windowUI.activePane = .search
            windowUI.searchQuery = target.sectionNumber
            return nil
        }
    }

    public func toggleSplitPane() {
        if document.splitPane != nil {
            document.closeSplitPane()
        } else if let current = document.activeTab?.route {
            let companion = corpus.defaultCompanionRoute(for: current)
            document.openInSplitPane(companion)
            windowUI.activePane = .reader
        }
    }

    // MARK: - Minimal Sidebar

    private var sidebarList: some View {
        let openTodoCount = document.todos.filter { !$0.isCompleted }.count

        return List(selection: $windowUI.activePane) {
            Label("Search", systemImage: "magnifyingglass")
                .tag(WorkspaceSection.search)

            if !document.tabs.isEmpty {
                Label("Reader", systemImage: "doc.text")
                    .badge(document.tabs.count)
                    .tag(WorkspaceSection.reader)
            }

            Label("Entities", systemImage: "building.2")
                .badge(document.entities.count)
                .tag(WorkspaceSection.entities)

            Label("Assets", systemImage: "cube.box")
                .badge(document.assets.count)
                .tag(WorkspaceSection.assets)

            Label("To-Do", systemImage: "checklist")
                .badge(openTodoCount)
                .tag(WorkspaceSection.todos)

            Label("Day Count", systemImage: "calendar")
                .tag(WorkspaceSection.dayCount)

            if !document.pinnedProvisions.isEmpty {
                Section("Pinned") {
                    ForEach(document.pinnedProvisions) { pin in
                        let title = corpus.title(forSectionID: pin.route.sectionID)
                        Button {
                            openRoute(pin.route, inNewTab: false)
                        } label: {
                            HStack(spacing: 4) {
                                Text(title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                if let anchor = pin.route.anchor {
                                    Text("(\(anchor.replacingOccurrences(of: "/", with: ")(")))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Pin", role: .destructive) {
                                document.togglePin(pin.route)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailContent: some View {
        switch windowUI.activePane {
        case .search:
            searchCanvas
        case .reader:
            if document.tabs.isEmpty {
                searchCanvas
            } else {
                readerWorkspace
            }
        case .entities:
            EntitiesPrimitiveView(
                entities: $document.entities,
                selectedID: $windowUI.selectedEntityID,
                onAdd: createNewEntity
            )
        case .assets:
            AssetsPrimitiveView(
                assets: $document.assets,
                entities: document.entities,
                selectedID: $windowUI.selectedAssetID,
                onAdd: createNewAsset
            )
        case .todos:
            TodoPrimitiveView(todos: $document.todos)
        case .dayCount:
            DayCountPrimitiveView(state: $document.dayCount)
        }
    }

    // MARK: - Clean Search Box Canvas (Zero Verbiage)

    private var searchCanvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search", text: $windowUI.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($searchFieldFocused)
                    .onSubmit {
                        if let first = windowUI.searchHits.first {
                            openRoute(
                                ProvisionRoute(sectionID: first.summary.id, anchor: first.targetAnchor),
                                inNewTab: false
                            )
                        } else if let target = CitationResolver.parse(windowUI.searchQuery) {
                            openCitation(target, disposition: .currentPane)
                        }
                    }

                if !windowUI.searchQuery.isEmpty {
                    Button {
                        windowUI.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Picker("", selection: $windowUI.searchScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(16)

            if !windowUI.searchHits.isEmpty {
                Divider()
                List(windowUI.searchHits) { hit in
                    let route = ProvisionRoute(sectionID: hit.summary.id, anchor: hit.targetAnchor)
                    Button {
                        openRoute(route, inNewTab: false)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(hit.summary.heading.isEmpty ? hit.summary.displayTitle : hit.summary.heading)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                HStack(spacing: 3) {
                                    Text(hit.summary.displayTitle)
                                    if let anchor = hit.targetAnchor {
                                        Text("(\(anchor.replacingOccurrences(of: "/", with: ")(")))")
                                    }
                                }
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }

                            if !hit.summary.breadcrumb.isEmpty {
                                Text(hit.summary.breadcrumb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Text(Self.renderSnippet(hit.snippet))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { openRoute(route, inNewTab: false) }
                        Button("Open in New Tab") { openRoute(route, inNewTab: true) }
                        Button("Open in Split View") {
                            document.openInSplitPane(route)
                            windowUI.activePane = .reader
                        }
                        Button("Open in Separate Window") { openWindow(value: route) }
                    }
                }
                .listStyle(.plain)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static func renderSnippet(_ rawSnippet: String) -> AttributedString {
        var result = AttributedString()
        var remainder = rawSnippet[...]
        while let openIdx = remainder.firstIndex(of: "«") {
            let before = String(remainder[..<openIdx])
            if !before.isEmpty {
                result.append(AttributedString(before))
            }
            let afterOpen = remainder.index(after: openIdx)
            if let closeIdx = remainder[afterOpen...].firstIndex(of: "»") {
                var boldPart = AttributedString(String(remainder[afterOpen..<closeIdx]))
                boldPart.inlinePresentationIntent = .stronglyEmphasized
                boldPart.foregroundColor = .primary
                result.append(boldPart)
                remainder = remainder[remainder.index(after: closeIdx)...]
            } else {
                result.append(AttributedString(String(remainder[openIdx...])))
                return result
            }
        }
        if !remainder.isEmpty {
            result.append(AttributedString(String(remainder)))
        }
        return result
    }

    // MARK: - Reader Workspace (Tabs + Split Pane)

    private var readerWorkspace: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            if let activeTab = document.activeTab {
                if let split = document.splitPane {
                    HStack(spacing: 0) {
                        ProvisionReaderView(
                            route: activeTab.route,
                            document: $document,
                            corpus: corpus,
                            isSplitSecondary: false,
                            onNavigate: { nextRoute in openRoute(nextRoute, inNewTab: false) },
                            onOpenCitation: { target, disp in _ = openCitation(target, disposition: disp) }
                        )
                        .frame(minWidth: 320, maxWidth: .infinity)

                        Divider()

                        secondarySplitPaneView(split: split)
                            .frame(minWidth: 320, maxWidth: .infinity)
                    }
                } else {
                    ProvisionReaderView(
                        route: activeTab.route,
                        document: $document,
                        corpus: corpus,
                        isSplitSecondary: false,
                        onNavigate: { nextRoute in openRoute(nextRoute, inNewTab: false) },
                        onOpenCitation: { target, disp in _ = openCitation(target, disposition: disp) }
                    )
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    document.goBackInActiveTab { corpus.title(forSectionID: $0) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(document.activeTab?.backStack.isEmpty ?? true)

                Button {
                    document.goForwardInActiveTab { corpus.title(forSectionID: $0) }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(document.activeTab?.forwardStack.isEmpty ?? true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(document.tabs) { tab in
                        let isSelected = (tab.id == document.activeTab?.id)
                        HStack(spacing: 6) {
                            Button {
                                document.activeTabID = tab.id
                            } label: {
                                Text(tab.title)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)

                            Button {
                                document.closeTab(tab.id)
                                if document.tabs.isEmpty {
                                    windowUI.activePane = .search
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contextMenu {
                            Button("Open in Separate Window") { openWindow(value: tab.route) }
                            Button("Open in Split View") { document.openInSplitPane(tab.route) }
                            Divider()
                            Button("Close Tab", role: .destructive) { document.closeTab(tab.id) }
                        }
                    }
                }
            }

            Spacer()

            Button {
                toggleSplitPane()
            } label: {
                Image(systemName: document.splitPane == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle Split View (⇧⌘D)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func secondarySplitPaneView(split: SplitPaneState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { document.goBackInSplitPane() } label: { Image(systemName: "chevron.left") }
                    .disabled(split.backStack.isEmpty)
                Button { document.goForwardInSplitPane() } label: { Image(systemName: "chevron.right") }
                    .disabled(split.forwardStack.isEmpty)

                Spacer()

                Button("Tab") {
                    openRoute(split.route, inNewTab: true)
                }
                .font(.caption)

                Button {
                    document.closeSplitPane()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            ProvisionReaderView(
                route: split.route,
                document: $document,
                corpus: corpus,
                isSplitSecondary: true,
                onNavigate: { nextRoute in document.openInSplitPane(nextRoute) },
                onOpenCitation: { target, disp in _ = openCitation(target, disposition: disp) }
            )
        }
    }
}
