import Foundation

/// An indexed statutory or regulatory corpus (e.g., Title 26 IRC or CFR Title 26 Treasury Regulations)
/// providing O(1) lookup by citation URI or section number.
public struct LegalCorpus: Sendable {
    public let root: DocumentNode
    public let title: String?
    public let sections: [Provision]
    private let byIdentifier: [String: Provision]
    private let sectionsByNumber: [String: [Provision]]

    public init(root: DocumentNode) {
        self.root = root
        var sections: [Provision] = []
        var byIdentifier: [String: Provision] = [:]
        var sectionsByNumber: [String: [Provision]] = [:]

        Self.indexTree(
            node: root,
            sections: &sections,
            byIdentifier: &byIdentifier,
            sectionsByNumber: &sectionsByNumber
        )

        self.sections = sections
        self.byIdentifier = byIdentifier
        self.sectionsByNumber = sectionsByNumber
        self.title = root.firstElement(forKey: "dc:title", recursive: true)?.normalizedText
            ?? root.firstElement(forKey: "TITLENUM", recursive: true)?.normalizedText
            ?? Self.collectTopLevel(in: root).first?.heading
    }

    public static func loadXML(contentsOf url: URL) throws -> LegalCorpus {
        try LegalCorpus(root: DocumentNode.parseXML(contentsOf: url))
    }

    public static func loadXML(data: Data) throws -> LegalCorpus {
        try LegalCorpus(root: DocumentNode.parseXML(data: data))
    }

    /// Outermost structural containers (e.g., `Title 26` in USLM or `TITLE` in CFR).
    public var topLevelProvisions: [Provision] {
        Self.collectTopLevel(in: root)
    }

    /// O(1) lookup by canonical URI (`"/us/usc/t26/s1/a/1"`) or section number (`"162"`, `"§ 1.141-1"`).
    public subscript(_ query: String) -> Provision? {
        byIdentifier[query] ?? section(query)
    }

    /// Returns the first section matching `number` (e.g., `"1"`, `"§ 162"`, `"1.141-1"`, `"§ 1.141-1"`).
    public func section(_ number: String) -> Provision? {
        sections(number).first
    }

    /// Returns all sections matching `number` (in case a corpus spans multiple parts/volumes with shared numbers).
    public func sections(_ number: String) -> [Provision] {
        guard let key = Provision.normalizeDesignator(number) else { return [] }
        return sectionsByNumber[key] ?? []
    }

    private static func indexTree(
        node: DocumentNode,
        sections: inout [Provision],
        byIdentifier: inout [String: Provision],
        sectionsByNumber: inout [String: [Provision]]
    ) {
        // Skip quoted statutory amendments inside notes/prose so only live provisions are indexed.
        guard node.key != "quotedContent" else { return }

        if Provision.structuralKeys.contains(node.key) {
            let provision = Provision(raw: node)
            if let id = node[attribute: "identifier"] ?? node[attribute: "NODE"], byIdentifier[id] == nil {
                byIdentifier[id] = provision
            }
            if Provision.isSection(node) {
                sections.append(provision)
                if let key = Provision.normalizeDesignator(provision.value ?? provision.number) {
                    sectionsByNumber[key, default: []].append(provision)
                }
            }
        }

        for child in node.children {
            if case .element(let elem) = child {
                indexTree(
                    node: elem,
                    sections: &sections,
                    byIdentifier: &byIdentifier,
                    sectionsByNumber: &sectionsByNumber
                )
            }
        }
    }

    private static func collectTopLevel(in node: DocumentNode) -> [Provision] {
        if Provision.structuralKeys.contains(node.key) {
            return [Provision(raw: node)]
        }
        var results: [Provision] = []
        for child in node.children {
            if case .element(let elem) = child {
                results.append(contentsOf: collectTopLevel(in: elem))
            }
        }
        return results
    }
}
