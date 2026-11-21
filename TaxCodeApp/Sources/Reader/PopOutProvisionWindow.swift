import SwiftUI
import TaxData

public struct PopOutProvisionWindow: View {
    public let initialRoute: ProvisionRoute?
    public let corpus: CorpusController
    @State private var currentRoute: ProvisionRoute?
    @State private var backStack: [ProvisionRoute] = []
    @State private var forwardStack: [ProvisionRoute] = []

    public init(initialRoute: ProvisionRoute?, corpus: CorpusController) {
        self.initialRoute = initialRoute
        self.corpus = corpus
        self._currentRoute = State(initialValue: initialRoute)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let route = currentRoute {
                HStack(spacing: 8) {
                    Button {
                        if let prev = backStack.popLast() {
                            forwardStack.append(route)
                            currentRoute = prev
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(backStack.isEmpty)

                    Button {
                        if let next = forwardStack.popLast() {
                            backStack.append(route)
                            currentRoute = next
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(forwardStack.isEmpty)

                    Text(corpus.title(forSectionID: route.sectionID))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                ProvisionReaderView(
                    route: route,
                    document: nil,
                    corpus: corpus,
                    isSplitSecondary: false,
                    isPopOutWindow: true,
                    onNavigate: { next in
                        if next != route {
                            backStack.append(route)
                            forwardStack.removeAll()
                            currentRoute = next
                        }
                    }
                )
            } else {
                ContentUnavailableView("Select a Provision", systemImage: "doc.text")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}
