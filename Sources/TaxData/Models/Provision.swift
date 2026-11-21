import Foundation

/// A single statutory or regulatory division (Title, Subtitle, Chapter, Part, Section,
/// Subsection, Paragraph, Clause, etc.) backed losslessly by `DocumentNode`.
///
/// Works uniformly across:
/// - **USLM 1.0 XML** (`title26.xml` / `usc26.xml` / U.S. Code, Securities Act, Public Laws)
/// - **GPO CFR Merged XML** (`CFR-*-title26-*.xml` / Annual Code of Federal Regulations)
/// - **eCFR Bulk XML** (`ECFR-title*.xml` / `<DIV1>`–`<DIV9>`)
public struct Provision: Sendable, Hashable {
    public let raw: DocumentNode

    public init(raw: DocumentNode) {
        self.raw = raw
    }

    /// All 26 `LevelType` elements from `USLM-1.0.15.xsd` plus GPO CFR & eCFR container tags.
    public static let structuralKeys: Set<String> = [
        // USLM LevelType synonyms
        "level", "preliminary", "title", "subtitle", "part", "subpart",
        "division", "subdivision", "chapter", "subchapter", "article", "subarticle",
        "compiledAct", "courtRules", "courtRule", "reorganizationPlans", "reorganizationPlan",
        "section", "subsection", "paragraph", "subparagraph", "clause", "subclause",
        "item", "subitem", "subsubitem",
        // GPO CFR Merged XML
        "TITLE", "SUBTITLE", "CHAPTER", "SUBCHAP", "PART", "SUBPART", "SUBJGRP", "SECTION", "APPENDIX",
        // eCFR Bulk XML
        "DIV1", "DIV2", "DIV3", "DIV4", "DIV5", "DIV6", "DIV7", "DIV8", "DIV9",
    ]

    private static let apparatusKeys: Set<String> = [
        "notes", "note", "sourceCredit", "toc",
        "TOC", "CONTENTS", "CFRTOC", "CITA", "SECAUTH", "EDNOTE", "AUTH", "SOURCE", "PRTPAGE", "NOTE",
    ]

    private static let headingKeys = ["heading", "SUBJECT", "HEAD", "HD", "RESERVED"]
    private static let paragraphKeys: Set<String> = [
        "P", "FP", "p", "chapeau", "content", "continuation", "proviso", "EXAMPLE", "EXTRACT",
    ]
    private static let directNoteKeys: Set<String> = ["note", "EDNOTE", "CITA", "NOTE"]

    /// Normalized structural tier name (e.g., `"section"`, `"subsection"`, `"part"`).
    public var kind: String {
        (raw[attribute: "TYPE"] ?? raw.key).lowercased()
    }

    /// Canonical identifier URI or node ID when present (e.g., `"/us/usc/t26/s1/a/1"`).
    public var identifier: String? {
        raw[attribute: "identifier"] ?? raw[attribute: "NODE"] ?? raw[attribute: "id"]
    }

    /// Machine-normalized designator value in USLM (e.g., `"1"`, `"a"`, `"162"`).
    public var value: String? {
        raw.firstElement(forKey: "num")?[attribute: "value"]
    }

    /// Human-readable number/designation (e.g., `"§ 1."`, `"(a)"`, `"§ 1.141-1"`).
    public var number: String? {
        raw.firstElement(forKey: "num")?.normalizedText
            ?? raw.firstElement(forKey: "SECTNO")?.normalizedText
            ?? raw[attribute: "N"]
    }

    /// Clean section or division heading (e.g., `"Tax imposed"`, `"Income tax on individuals."`).
    public var heading: String? {
        for key in Self.headingKeys {
            if let text = raw.firstElement(forKey: key)?.normalizedText, !text.isEmpty {
                // In eCFR `<DIV8 N="§ 1.1-1"><HEAD>§ 1.1-1 Income tax on individuals.</HEAD>`,
                // strip the repeated section designator prefix so headings match GPO/USLM cleanly.
                if Self.isSection(raw), let nAttr = raw[attribute: "N"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !nAttr.isEmpty, text.hasPrefix(nAttr) {
                    let stripped = text.dropFirst(nAttr.count)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " —–-"))
                    if !stripped.isEmpty {
                        return stripped
                    }
                }
                return text
            }
        }
        return nil
    }

    /// Operative statutory or regulatory text, excluding editorial/statutory notes, source credits, TOCs, and page breaks.
    public var bodyText: String {
        var buffer = ""
        Self.appendBodyText(from: raw, into: &buffer)
        return DocumentNode.collapseWhitespace(buffer)
    }

    /// Complete normalized text including notes, source credits, and apparatus.
    public var fullText: String {
        raw.normalizedText
    }

    /// Direct text/paragraph blocks within this provision (ideal for flat `<P>` regulatory sections).
    public var paragraphs: [String] {
        raw.elements.compactMap { child in
            guard Self.paragraphKeys.contains(child.key) else { return nil }
            let text = Provision(raw: child).bodyText
            return text.isEmpty ? nil : text
        }
    }

    /// Attached statutory/editorial notes, footnotes, and regulatory source citations.
    public var notes: [DocumentNode] {
        var result: [DocumentNode] = []
        for child in raw.elements {
            if Self.directNoteKeys.contains(child.key) {
                result.append(child)
            } else if child.key == "notes" {
                result.append(contentsOf: child["note"])
            }
        }
        return result
    }

    /// All cross-reference URIs (`href`) cited anywhere inside this provision.
    public var references: [String] {
        raw.strings(forKey: "href", recursive: true)
    }

    /// Direct child structural divisions (e.g., subsections of a section, paragraphs of a subsection).
    public var children: [Provision] {
        raw.elements.compactMap { Self.structuralKeys.contains($0.key) ? Provision(raw: $0) : nil }
    }

    /// Drills into a direct child division by designator (`section["a"]?["1"]` or `section["(a)"]`).
    public subscript(_ designator: String) -> Provision? {
        guard let target = Self.normalizeDesignator(designator) else { return nil }
        return children.first { child in
            Self.normalizeDesignator(child.value) == target
                || Self.normalizeDesignator(child.number) == target
        }
    }

    public static func isSection(_ node: DocumentNode) -> Bool {
        node.key == "section"
            || node.key == "SECTION"
            || (node.key.hasPrefix("DIV") && node[attribute: "TYPE"] == "SECTION")
    }

    public static func normalizeDesignator(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, first == "§" || first.isWhitespace {
            s.removeFirst()
        }
        while let last = s.last, last == "." || last == "—" || last == "–" || last.isWhitespace {
            s.removeLast()
        }
        if s.count >= 2, s.first == "(", s.last == ")" {
            let inner = s.dropFirst().dropLast()
            if !inner.contains("(") && !inner.contains(")") {
                s = String(inner)
            }
        }
        return s.isEmpty ? nil : s
    }

    private static func appendBodyText(from node: DocumentNode, into buffer: inout String) {
        for child in node.children {
            switch child {
            case .text(let chunk):
                buffer.append(chunk)
            case .element(let elem):
                guard !apparatusKeys.contains(elem.key) else { continue }
                appendBodyText(from: elem, into: &buffer)
            }
        }
    }
}
