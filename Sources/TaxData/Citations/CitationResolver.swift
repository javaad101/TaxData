import Foundation

/// Represents a parsed legal citation pointing to an IRC or Treasury Regulation section
/// and an optional chain of subsection/paragraph designators (e.g., `["a", "2"]`).
public struct CitationTarget: Sendable, Hashable, Codable {
    public enum CorpusKind: String, Sendable, Hashable, Codable {
        case irc = "IRC"
        case cfr = "CFR"
    }

    public var corpus: CorpusKind
    public var sectionNumber: String
    public var subsections: [String]

    public init(corpus: CorpusKind, sectionNumber: String, subsections: [String] = []) {
        self.corpus = corpus
        self.sectionNumber = sectionNumber
        self.subsections = subsections
    }

    /// Normalized anchor key (e.g. `"a/2"` for `(a)(2)`), if subsection designators were supplied.
    public var subsectionAnchor: String? {
        subsections.isEmpty ? nil : subsections.joined(separator: "/")
    }

    /// Canonical query string suitable for URL schemes (`taxlaw://cite/...`).
    public var canonicalString: String {
        let tail = subsections.map { "(\($0))" }.joined()
        switch corpus {
        case .irc:
            return "IRC \(sectionNumber)\(tail)"
        case .cfr:
            return "Reg \(sectionNumber)\(tail)"
        }
    }
}

public enum CitationResolver {
    /// Parses user input or a reference string into a structured `CitationTarget` if it looks
    /// like a statutory or regulatory citation rather than a free-text search query.
    public static func parse(_ rawInput: String) -> CitationTarget? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Direct USLM URI: /us/usc/t26/s162/a/2
        if trimmed.hasPrefix("/us/usc/t26/s") {
            let remainder = trimmed.dropFirst("/us/usc/t26/s".count)
            let parts = remainder.split(separator: "/").map(String.init)
            guard let sec = parts.first, !sec.isEmpty else { return nil }
            return CitationTarget(corpus: .irc, sectionNumber: sec, subsections: Array(parts.dropFirst()))
        }

        // 2. Database synthetic CFR ID: cfr:26:1.141-1
        if trimmed.hasPrefix("cfr:26:") {
            let sec = String(trimmed.dropFirst("cfr:26:".count))
            guard !sec.isEmpty else { return nil }
            return CitationTarget(corpus: .cfr, sectionNumber: sec)
        }

        // Strip common prefixes (IRC, I.R.C., 26 U.S.C., Treas. Reg., 26 C.F.R., Section, Sec., §)
        var working = trimmed
        let lower = working.lowercased()
        var forcedCorpus: CitationTarget.CorpusKind?

        let cfrPrefixes = [
            "treas. reg.", "treas reg", "treasury regulation", "treasury reg.",
            "26 c.f.r.", "26 cfr", "c.f.r.", "cfr", "reg.", "reg ",
        ]
        let ircPrefixes = [
            "i.r.c.", "irc", "26 u.s.c.", "26 usc", "u.s.c.", "usc",
        ]
        let neutralPrefixes = ["sections", "section", "secs.", "sec."]

        for prefix in cfrPrefixes where lower.hasPrefix(prefix) {
            forcedCorpus = .cfr
            working = String(working.dropFirst(prefix.count))
            break
        }
        if forcedCorpus == nil {
            for prefix in ircPrefixes where lower.hasPrefix(prefix) {
                forcedCorpus = .irc
                working = String(working.dropFirst(prefix.count))
                break
            }
        }
        let workingLower = working.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in neutralPrefixes where workingLower.hasPrefix(prefix) {
            working = String(working.trimmingCharacters(in: .whitespaces).dropFirst(prefix.count))
            break
        }

        working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = working.first, first == "§" || first.isWhitespace {
            working.removeFirst()
        }
        while let last = working.last, last == "." || last.isWhitespace {
            working.removeLast()
        }
        guard !working.isEmpty, !working.contains(" ") else { return nil }

        // 3. CFR pattern: <part>.<section>(optionalSub)-<regNum>(optionalTrailingSubs)
        //    Examples: 1.141-1, 1.704-1(b)(2)(ii), 1.1(h)-1, 301.7701-3(a), 602.101
        if working.contains(".") {
            guard forcedCorpus != .irc else { return nil }
            if let (cfrSec, subs) = splitCFRSectionAndSubsections(working) {
                return CitationTarget(corpus: .cfr, sectionNumber: cfrSec, subsections: subs)
            }
            return nil
        }

        // 4. IRC pattern: <digits><optionalLetters>(optionalTrailingSubs)
        //    Examples: 1, 162, 162(a)(2), 25A(i), 7701(a)(3)
        guard forcedCorpus != .cfr else { return nil }
        if let (ircSec, subs) = splitIRCSectionAndSubsections(working) {
            return CitationTarget(corpus: .irc, sectionNumber: ircSec, subsections: subs)
        }
        return nil
    }

    /// Extracts the underlying IRC section number for a Title 26 CFR regulation number.
    /// Examples:
    /// - `"1.141-1"` -> `"141"`
    /// - `"1.1(h)-1"` -> `"1"`
    /// - `"1.25A-1"` -> `"25A"`
    /// - `"301.7701-3"` -> `"7701"`
    /// - `"602.101"` -> `nil`
    public static func parentIRCSection(forCFRNumber cfrNumber: String) -> String? {
        let cleaned = Provision.normalizeDesignator(cfrNumber) ?? cfrNumber
        guard let dotIndex = cleaned.firstIndex(of: ".") else { return nil }
        let afterDot = cleaned[cleaned.index(after: dotIndex)...]
        guard let dashIndex = afterDot.firstIndex(of: "-") else { return nil }
        var middle = String(afterDot[..<dashIndex])
        if let parenIndex = middle.firstIndex(of: "(") {
            middle = String(middle[..<parenIndex])
        }
        guard let first = middle.first, first.isNumber else { return nil }
        return middle
    }

    /// Splits prose into plain text runs and clickable inline statutory/regulatory citations.
    public enum TextSegment: Sendable, Hashable {
        case text(String)
        case citation(label: String, target: CitationTarget)
    }

    private static let inlineCitationRegex: NSRegularExpression = {
        let pattern = #"(?:§§?\s*\d+\.\d+[A-Za-z]*(?:\([^)\s]+\))*-\d+[A-Za-z]*(?:\([^)\s,;.]+\))*)|(?:\b(?:[Ss]ection|26\s+U\.S\.C\.|I\.R\.C\.\s*§?)\s+\d+[A-Za-z]*(?:\([A-Za-z0-9]+\))*)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    public static func segmentInlineCitations(in text: String) -> [TextSegment] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = inlineCitationRegex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return [.text(text)] }

        var segments: [TextSegment] = []
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                segments.append(.text(String(text[cursor..<range.lowerBound])))
            }
            let matchedString = String(text[range])
            if let target = parse(matchedString) {
                segments.append(.citation(label: matchedString, target: target))
            } else {
                segments.append(.text(matchedString))
            }
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            segments.append(.text(String(text[cursor..<text.endIndex])))
        }
        return segments
    }

    // MARK: - Helpers

    private static func splitIRCSectionAndSubsections(_ token: String) -> (String, [String])? {
        let parenStart = token.firstIndex(of: "(") ?? token.endIndex
        let base = String(token[..<parenStart])
        guard let first = base.first, first.isNumber else { return nil }
        guard base.allSatisfy({ $0.isNumber || $0.isLetter }) else { return nil }

        let remainder = String(token[parenStart...])
        guard let subs = parseParenthesizedChain(remainder) else { return nil }
        return (base, subs)
    }

    private static func splitCFRSectionAndSubsections(_ token: String) -> (String, [String])? {
        if let dashIndex = token.firstIndex(of: "-") {
            let afterDash = token[token.index(after: dashIndex)...]
            let trailingParen = afterDash.firstIndex(of: "(") ?? token.endIndex
            let base = String(token[..<trailingParen])
            guard let first = base.first, first.isNumber else { return nil }
            let remainder = String(token[trailingParen...])
            guard let subs = parseParenthesizedChain(remainder) else { return nil }
            return (base, subs)
        } else {
            let parenStart = token.firstIndex(of: "(") ?? token.endIndex
            let base = String(token[..<parenStart])
            let parts = base.split(separator: ".")
            guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
            let remainder = String(token[parenStart...])
            guard let subs = parseParenthesizedChain(remainder) else { return nil }
            return (base, subs)
        }
    }

    private static func parseParenthesizedChain(_ text: String) -> [String]? {
        guard !text.isEmpty else { return [] }
        var subs: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            guard text[idx] == "(" else { return nil }
            let innerStart = text.index(after: idx)
            guard let closeIdx = text[innerStart...].firstIndex(of: ")") else { return nil }
            let value = String(text[innerStart..<closeIdx])
            guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            subs.append(value)
            idx = text.index(after: closeIdx)
        }
        return subs
    }
}
