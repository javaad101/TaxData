import Foundation
import SwiftUI
import TaxData

/// A single flat, gutter-aligned reading/editing unit:
/// - `gutterLabel`: Minimized designator shown in the delineated left gutter (e.g., `"(a)"`, `"(1)"`, `"(i)"`).
/// - `heading`: Clean plain-string heading rendered in its own standalone `Text` view.
/// - `content`: Either an editable `AttributedString` body (rendered in its own `TextEditor` instance) or a table.
struct RenderedProvisionBlock: Identifiable, Sendable {
    enum ContentKind: Sendable {
        case none
        case textBlock(defaultAttributed: AttributedString, citations: [CitationTarget], isExtract: Bool)
        case table(node: DocumentNode)
    }

    let id: String
    let storageKey: String
    let anchorPath: String?
    let gutterLabel: String?
    let heading: String?
    let plainTextLowercased: String
    let content: ContentKind
}

enum ProvisionBlockCompiler {
    private static let skippedKeys: Set<String> = [
        "num", "SECTNO", "heading", "SUBJECT", "HEAD", "HD", "RESERVED",
        "notes", "note", "sourceCredit", "toc", "TOC", "CONTENTS", "CFRTOC",
        "CITA", "SECAUTH", "EDNOTE", "AUTH", "SOURCE", "PRTPAGE", "NOTE",
    ]

    private static let proseElementKeys: Set<String> = [
        "chapeau", "content", "p", "P", "FP", "continuation", "proviso",
    ]

    static func compile(sectionID: String, provision: Provision, corpus: CitationTarget.CorpusKind) -> [RenderedProvisionBlock] {
        var blocks: [RenderedProvisionBlock] = []
        blocks.reserveCapacity(64)
        var usedIDs = Set<String>()
        var serial = 0

        func makeIDs(preferredAnchor: String?) -> (viewID: String, storageKey: String) {
            serial += 1
            let storageKey = "\(sectionID)#\(preferredAnchor ?? "b\(serial)")#\(serial)"
            if let anchor = preferredAnchor, !anchor.isEmpty {
                let candidate = "anchor:\(anchor)"
                if usedIDs.insert(candidate).inserted {
                    return (candidate, storageKey)
                }
            }
            return ("blk:\(serial)", storageKey)
        }

        func emitUSLMOrGenericChildren(of node: DocumentNode, anchorPrefix: String, inExtract: Bool) {
            let children = node.elements.filter { !skippedKeys.contains($0.key) }
            var index = 0

            while index < children.count {
                let elem = children[index]

                if Provision.structuralKeys.contains(elem.key) {
                    emitStructuralNode(elem, anchorPrefix: anchorPrefix, inExtract: inExtract)
                    index += 1
                } else if elem.key == "table" || elem.key == "TABLE" || elem.key == "GPOTABLE" {
                    let ids = makeIDs(preferredAnchor: nil)
                    blocks.append(RenderedProvisionBlock(
                        id: ids.viewID,
                        storageKey: ids.storageKey,
                        anchorPath: anchorPrefix.isEmpty ? nil : anchorPrefix,
                        gutterLabel: nil,
                        heading: nil,
                        plainTextLowercased: elem.normalizedText.lowercased(),
                        content: .table(node: elem)
                    ))
                    index += 1
                } else if elem.key == "DIV",
                          let nestedTable = elem.firstDescendant(where: { $0.key == "TABLE" || $0.key == "table" || $0.key == "GPOTABLE" }) {
                    let ids = makeIDs(preferredAnchor: nil)
                    blocks.append(RenderedProvisionBlock(
                        id: ids.viewID,
                        storageKey: ids.storageKey,
                        anchorPath: anchorPrefix.isEmpty ? nil : anchorPrefix,
                        gutterLabel: nil,
                        heading: nil,
                        plainTextLowercased: nestedTable.normalizedText.lowercased(),
                        content: .table(node: nestedTable)
                    ))
                    index += 1
                } else if elem.key == "EXTRACT" || elem.key == "EXAMPLE" || elem.key == "quotedContent" {
                    if elem.elements.isEmpty {
                        emitCFRStyleParagraph(node: elem, anchorPrefix: anchorPrefix, isExtract: true)
                    } else {
                        emitUSLMOrGenericChildren(of: elem, anchorPrefix: anchorPrefix, inExtract: true)
                    }
                    index += 1
                } else if corpus == .cfr {
                    emitCFRStyleParagraph(node: elem, anchorPrefix: anchorPrefix, isExtract: inExtract)
                    index += 1
                } else {
                    let (attr, cites, plain) = buildAttributedFromChildren(elem.children)
                    if !plain.isEmpty {
                        let ids = makeIDs(preferredAnchor: nil)
                        blocks.append(RenderedProvisionBlock(
                            id: ids.viewID,
                            storageKey: ids.storageKey,
                            anchorPath: anchorPrefix.isEmpty ? nil : anchorPrefix,
                            gutterLabel: nil,
                            heading: nil,
                            plainTextLowercased: plain.lowercased(),
                            content: .textBlock(defaultAttributed: attr, citations: cites, isExtract: inExtract)
                        ))
                    }
                    index += 1
                }
            }
        }

        func emitStructuralNode(_ elem: DocumentNode, anchorPrefix: String, inExtract: Bool) {
            let childProv = Provision(raw: elem)
            let localDes = Provision.normalizeDesignator(childProv.value ?? childProv.number) ?? ""
            let nextAnchor = anchorPrefix.isEmpty
                ? localDes
                : (localDes.isEmpty ? anchorPrefix : "\(anchorPrefix)/\(localDes)")

            let gutter = cleanGutterDesignator(childProv.number)
            let heading = cleanHeadingString(childProv.heading)

            let innerElements = elem.elements.filter { !skippedKeys.contains($0.key) }

            // In USLM, attach the immediate opening prose (<chapeau> or <content>) directly under this node's heading + gutter!
            if corpus == .irc, let firstInner = innerElements.first, proseElementKeys.contains(firstInner.key) {
                let (attr, cites, plain) = buildAttributedFromChildren(firstInner.children)
                let ids = makeIDs(preferredAnchor: nextAnchor)
                let combinedPlain = [gutter, heading, plain].compactMap { $0 }.joined(separator: " ").lowercased()
                blocks.append(RenderedProvisionBlock(
                    id: ids.viewID,
                    storageKey: ids.storageKey,
                    anchorPath: nextAnchor.isEmpty ? nil : nextAnchor,
                    gutterLabel: gutter,
                    heading: heading,
                    plainTextLowercased: combinedPlain,
                    content: plain.isEmpty ? .none : .textBlock(defaultAttributed: attr, citations: cites, isExtract: inExtract)
                ))

                // Emit any remaining children after the opening prose
                for remaining in innerElements.dropFirst() {
                    if Provision.structuralKeys.contains(remaining.key) {
                        emitStructuralNode(remaining, anchorPrefix: nextAnchor, inExtract: inExtract)
                    } else if remaining.key == "table" || remaining.key == "TABLE" || remaining.key == "GPOTABLE" {
                        let tIDs = makeIDs(preferredAnchor: nil)
                        blocks.append(RenderedProvisionBlock(
                            id: tIDs.viewID,
                            storageKey: tIDs.storageKey,
                            anchorPath: nextAnchor.isEmpty ? nil : nextAnchor,
                            gutterLabel: nil,
                            heading: nil,
                            plainTextLowercased: remaining.normalizedText.lowercased(),
                            content: .table(node: remaining)
                        ))
                    } else {
                        let (remAttr, remCites, remPlain) = buildAttributedFromChildren(remaining.children)
                        if !remPlain.isEmpty {
                            let remIDs = makeIDs(preferredAnchor: nil)
                            blocks.append(RenderedProvisionBlock(
                                id: remIDs.viewID,
                                storageKey: remIDs.storageKey,
                                anchorPath: nextAnchor.isEmpty ? nil : nextAnchor,
                                gutterLabel: nil,
                                heading: nil,
                                plainTextLowercased: remPlain.lowercased(),
                                content: .textBlock(defaultAttributed: remAttr, citations: remCites, isExtract: inExtract)
                            ))
                        }
                    }
                }
            } else {
                if gutter != nil || heading != nil {
                    let ids = makeIDs(preferredAnchor: nextAnchor)
                    let combinedPlain = [gutter, heading].compactMap { $0 }.joined(separator: " ").lowercased()
                    blocks.append(RenderedProvisionBlock(
                        id: ids.viewID,
                        storageKey: ids.storageKey,
                        anchorPath: nextAnchor.isEmpty ? nil : nextAnchor,
                        gutterLabel: gutter,
                        heading: heading,
                        plainTextLowercased: combinedPlain,
                        content: .none
                    ))
                }
                emitUSLMOrGenericChildren(of: elem, anchorPrefix: nextAnchor, inExtract: inExtract)
            }
        }

        // MARK: - CFR Paragraph Decomposition: `(b) <I>Heading</I>—(1) <I>Subheading.</I> Body...`

        func emitCFRStyleParagraph(node: DocumentNode, anchorPrefix: String, isExtract: Bool) {
            var slice = node.children[...]

            // Repeatedly peel off chained `(designator) <I>Heading</I>—` prefixes before the final paragraph body
            var currentGutter: String? = nil
            var currentHeading: String? = nil
            var currentAnchor: String? = nil

            while true {
                trimLeadingWhitespace(in: &slice)
                guard let (parsedDesignator, parsedAnchorToken, afterDesignator) = peelLeadingDesignator(from: slice) else {
                    break
                }

                currentGutter = parsedDesignator
                if currentAnchor == nil {
                    currentAnchor = parsedAnchorToken
                }
                slice = afterDesignator
                trimLeadingWhitespace(in: &slice)

                // Check if immediately followed by an italic heading element (<I>, <i>, or <E T="03"/"04">)
                if let firstContent = slice.first,
                   case .element(let elem) = firstContent,
                   isCFRHeadingElement(elem) {
                    currentHeading = cleanHeadingString(elem.normalizedText)
                    slice = slice.dropFirst()

                    // Strip any period right outside `</I>` (e.g. `<I>General rule</I>. `)
                    stripLeadingPeriodOrDashBeforeProse(in: &slice, preserveChainedDashDesignator: true)

                    // Check if chained straight into another subdivision: `—(1) <I>General rule.</I>`
                    if startsWithChainedDashAndDesignator(slice) {
                        stripLeadingDashesAndSpaces(in: &slice)
                        let ids = makeIDs(preferredAnchor: parsedAnchorToken)
                        let combinedPlain = [currentGutter, currentHeading].compactMap { $0 }.joined(separator: " ").lowercased()
                        blocks.append(RenderedProvisionBlock(
                            id: ids.viewID,
                            storageKey: ids.storageKey,
                            anchorPath: parsedAnchorToken,
                            gutterLabel: currentGutter,
                            heading: currentHeading,
                            plainTextLowercased: combinedPlain,
                            content: .none
                        ))
                        currentGutter = nil
                        currentHeading = nil
                        currentAnchor = nil
                        continue
                    }
                }
                break
            }

            // Also support standalone `<P><I>Example 1.</I> ...</P>` without parenthesized designator
            if currentGutter == nil && currentHeading == nil {
                trimLeadingWhitespace(in: &slice)
                if let firstContent = slice.first,
                   case .element(let elem) = firstContent,
                   isCFRHeadingElement(elem) {
                    let candidate = elem.normalizedText
                    if candidate.lowercased().hasPrefix("example") {
                        currentHeading = cleanHeadingString(candidate)
                        slice = slice.dropFirst()
                        stripLeadingPeriodOrDashBeforeProse(in: &slice, preserveChainedDashDesignator: false)
                    }
                }
            }

            let (attr, cites, plain) = buildAttributedFromChildren(Array(slice))
            guard currentGutter != nil || currentHeading != nil || !plain.isEmpty else { return }

            let effectiveAnchor = currentAnchor ?? (anchorPrefix.isEmpty ? nil : anchorPrefix)
            let ids = makeIDs(preferredAnchor: currentAnchor)
            let combinedPlain = [currentGutter, currentHeading, plain].compactMap { $0 }.joined(separator: " ").lowercased()

            blocks.append(RenderedProvisionBlock(
                id: ids.viewID,
                storageKey: ids.storageKey,
                anchorPath: effectiveAnchor,
                gutterLabel: currentGutter,
                heading: currentHeading,
                plainTextLowercased: combinedPlain,
                content: plain.isEmpty ? .none : .textBlock(defaultAttributed: attr, citations: cites, isExtract: isExtract)
            ))
        }

        emitUSLMOrGenericChildren(of: provision.raw, anchorPrefix: "", inExtract: false)
        return blocks
    }

    // MARK: - CFR Token Peeling Helpers

    private static func isCFRHeadingElement(_ elem: DocumentNode) -> Bool {
        if elem.key == "I" || elem.key == "i" { return true }
        if elem.key == "E", let t = elem[attribute: "T"], (t == "02" || t == "03" || t == "04") {
            return true
        }
        return false
    }

    private static func trimLeadingWhitespace(in slice: inout ArraySlice<DocumentNode.Content>) {
        while let first = slice.first {
            guard case .text(let s) = first else { break }
            let trimmed = String(s.drop(while: \.isWhitespace))
            if trimmed.isEmpty {
                slice.removeFirst()
            } else {
                if trimmed.count != s.count {
                    slice[slice.startIndex] = .text(trimmed)
                }
                break
            }
        }
    }

    /// Peels leading `(a)` or chained `(2)(i)` at the start of a paragraph text run.
    private static func peelLeadingDesignator(
        from slice: ArraySlice<DocumentNode.Content>
    ) -> (display: String, firstToken: String, remainder: ArraySlice<DocumentNode.Content>)? {
        guard let first = slice.first, case .text(let text) = first, text.first == "(" else {
            return nil
        }

        var cursor = text.startIndex
        var parts: [String] = []

        while cursor < text.endIndex && text[cursor] == "(" {
            let innerStart = text.index(after: cursor)
            guard let closeIdx = text[innerStart...].firstIndex(of: ")") else { break }
            let token = String(text[innerStart..<closeIdx])
            guard !token.isEmpty, token.count <= 5, token.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                break
            }
            parts.append(token)
            cursor = text.index(after: closeIdx)
        }

        guard let primary = parts.first else { return nil }
        let display = parts.map { "(\($0))" }.joined()
        let restText = String(text[cursor...])
        var nextSlice = slice.dropFirst()
        if !restText.isEmpty {
            var rebuilt = [DocumentNode.Content.text(restText)]
            rebuilt.append(contentsOf: nextSlice)
            nextSlice = rebuilt[...]
        }
        return (display, primary, nextSlice)
    }

    private static func startsWithChainedDashAndDesignator(_ slice: ArraySlice<DocumentNode.Content>) -> Bool {
        guard let first = slice.first, case .text(let s) = first else { return false }
        let trimmed = s.drop { $0.isWhitespace || $0 == "." }
        let afterDashes = trimmed.drop { $0 == "—" || $0 == "–" || $0 == "-" || $0.isWhitespace }
        guard afterDashes.count < trimmed.count, afterDashes.first == "(" else { return false }
        let innerStart = afterDashes.index(after: afterDashes.startIndex)
        guard let close = afterDashes[innerStart...].firstIndex(of: ")") else { return false }
        let token = afterDashes[innerStart..<close]
        return !token.isEmpty && token.count <= 5 && token.allSatisfy({ $0.isLetter || $0.isNumber })
    }

    private static func stripLeadingDashesAndSpaces(in slice: inout ArraySlice<DocumentNode.Content>) {
        guard let first = slice.first, case .text(let s) = first else { return }
        let rest = String(s.drop { $0.isWhitespace || $0 == "." || $0 == "—" || $0 == "–" || $0 == "-" })
        if rest.isEmpty {
            slice.removeFirst()
        } else {
            slice[slice.startIndex] = .text(rest)
        }
    }

    private static func stripLeadingPeriodOrDashBeforeProse(
        in slice: inout ArraySlice<DocumentNode.Content>,
        preserveChainedDashDesignator: Bool
    ) {
        if preserveChainedDashDesignator && startsWithChainedDashAndDesignator(slice) {
            return
        }
        guard let first = slice.first, case .text(let s) = first else { return }
        var rest = s[...]
        while let ch = rest.first, ch == "." || ch == "—" || ch == "–" || ch.isWhitespace {
            rest.removeFirst()
        }
        let cleaned = String(rest)
        if cleaned.isEmpty {
            slice.removeFirst()
        } else if cleaned.count != s.count {
            slice[slice.startIndex] = .text(cleaned)
        }
    }

    private static func cleanGutterDesignator(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var s = trimmed
        while let last = s.last, last == "." || last == "—" || last == "–" || last.isWhitespace {
            s.removeLast()
        }
        return s.isEmpty ? nil : s
    }

    private static func cleanHeadingString(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var s = trimmed
        while let last = s.last, last == "." || last == "—" || last == "–" || last == "-" || last.isWhitespace {
            s.removeLast()
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - AttributedString Builder (Size-Neutral for Live Zoom)

    private static func buildAttributedFromChildren(
        _ contents: [DocumentNode.Content]
    ) -> (AttributedString, [CitationTarget], String) {
        struct StyledRun {
            var text: String
            var isItalic: Bool
            var isBold: Bool
            var explicitHref: String?
        }

        var rawRuns: [StyledRun] = []
        func collectContent(_ list: [DocumentNode.Content], italic: Bool, bold: Bool, href: String?) {
            for item in list {
                switch item {
                case .text(let s):
                    rawRuns.append(StyledRun(text: s, isItalic: italic, isBold: bold, explicitHref: href))
                case .element(let elem):
                    guard elem.key != "PRTPAGE" && elem.key != "note" else { continue }
                    let nextItalic = italic || elem.key == "i" || elem.key == "I" || (elem.key == "E" && elem[attribute: "T"] != "04")
                    let nextBold = bold || elem.key == "b" || elem.key == "B" || elem.key == "HED"
                    let nextHref = (elem.key == "ref" ? elem[attribute: "href"] : nil) ?? href
                    collectContent(elem.children, italic: nextItalic, bold: nextBold, href: nextHref)
                }
            }
        }
        collectContent(contents, italic: false, bold: false, href: nil)

        var attributed = AttributedString()
        var plainBuffer = ""
        var discoveredTargets: [CitationTarget] = []
        var seenTargets = Set<CitationTarget>()
        var pendingSpace = false
        var hasEmittedContent = false

        func appendSegment(_ str: String, italic: Bool, bold: Bool, target: CitationTarget?) {
            guard !str.isEmpty else { return }
            plainBuffer.append(str)
            var attr = AttributedString(str)
            if italic && bold {
                attr.inlinePresentationIntent = [.emphasized, .stronglyEmphasized]
            } else if italic {
                attr.inlinePresentationIntent = .emphasized
            } else if bold {
                attr.inlinePresentationIntent = .stronglyEmphasized
            }
            if let target {
                if seenTargets.insert(target).inserted {
                    discoveredTargets.append(target)
                }
                if let encoded = target.canonicalString.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let url = URL(string: "taxlaw://cite/\(encoded)") {
                    attr.link = url
                }
            }
            attributed.append(attr)
        }

        for run in rawRuns {
            var normalizedRun = ""
            normalizedRun.reserveCapacity(run.text.count)
            for ch in run.text {
                if ch.isWhitespace {
                    if hasEmittedContent {
                        pendingSpace = true
                    }
                } else {
                    if pendingSpace {
                        normalizedRun.append(" ")
                        pendingSpace = false
                    }
                    normalizedRun.append(ch)
                    hasEmittedContent = true
                }
            }
            guard !normalizedRun.isEmpty else { continue }

            if let href = run.explicitHref, let explicitTarget = CitationResolver.parse(href) {
                appendSegment(normalizedRun, italic: run.isItalic, bold: run.isBold, target: explicitTarget)
            } else if mightContainInlineCitation(normalizedRun) {
                for seg in CitationResolver.segmentInlineCitations(in: normalizedRun) {
                    switch seg {
                    case .text(let plain):
                        appendSegment(plain, italic: run.isItalic, bold: run.isBold, target: nil)
                    case .citation(let label, let target):
                        appendSegment(label, italic: run.isItalic, bold: run.isBold, target: target)
                    }
                }
            } else {
                appendSegment(normalizedRun, italic: run.isItalic, bold: run.isBold, target: nil)
            }
        }

        return (attributed, discoveredTargets, plainBuffer)
    }

    private static func mightContainInlineCitation(_ text: String) -> Bool {
        text.contains("§")
            || text.contains("section ")
            || text.contains("Section ")
            || text.contains("U.S.C.")
            || text.contains("I.R.C.")
    }
}

// MARK: - Gutter-Delineated Scrollable Heading + TextEditor Sheet

struct GutterProvisionSheetView: View {
    static let gutterWidth: CGFloat = 68

    let blocks: [RenderedProvisionBlock]
    let fontSize: Double
    let highlightedAnchor: String?
    let filterQueryLowercased: String
    var document: Binding<TaxWorkflowDocument>?
    @Binding var transientEdits: [String: AttributedString]
    let onOpenCitation: (CitationTarget, OpenDisposition) -> Void
    let onPopOutCitation: (CitationTarget) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                if filterQueryLowercased.isEmpty || block.plainTextLowercased.contains(filterQueryLowercased) {
                    GutterBlockRowView(
                        block: block,
                        fontSize: fontSize,
                        isAnchorHighlighted: (highlightedAnchor != nil && block.anchorPath == highlightedAnchor),
                        document: document,
                        transientEdits: $transientEdits,
                        onOpenCitation: onOpenCitation,
                        onPopOutCitation: onPopOutCitation
                    )
                    .id(block.id)
                }
            }
        }
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(0.03))
                    .frame(width: Self.gutterWidth)
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
            }
        }
    }
}

private struct GutterBlockRowView: View {
    let block: RenderedProvisionBlock
    let fontSize: Double
    let isAnchorHighlighted: Bool
    var document: Binding<TaxWorkflowDocument>?
    @Binding var transientEdits: [String: AttributedString]
    let onOpenCitation: (CitationTarget, OpenDisposition) -> Void
    let onPopOutCitation: (CitationTarget) -> Void

    @State private var isHovered = false

    private func bindingForText(_ defaultText: AttributedString) -> Binding<AttributedString> {
        Binding<AttributedString>(
            get: {
                if let doc = document?.wrappedValue {
                    return doc.blockText(storageKey: block.storageKey, defaultText: defaultText)
                }
                return transientEdits[block.storageKey] ?? defaultText
            },
            set: { newValue in
                if let document {
                    document.wrappedValue.setBlockText(newValue, storageKey: block.storageKey, defaultText: defaultText)
                } else {
                    var cleaned = newValue
                    cleaned.font = nil
                    transientEdits[block.storageKey] = cleaned
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Delineated Left Gutter
            HStack(spacing: 0) {
                Spacer(minLength: 4)
                if let label = block.gutterLabel {
                    Text(label)
                        .font(.system(size: max(11, fontSize - 3), weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.trailing, 10)
            .padding(.top, block.heading != nil ? 9 : 11)
            .frame(width: GutterProvisionSheetView.gutterWidth, alignment: .trailing)

            // Vertical Gutter Rule Spacer (1pt drawn by parent background)
            Spacer().frame(width: 1)

            // Right Content Column: Standalone Heading `Text` + Editable `TextEditor`
            VStack(alignment: .leading, spacing: 4) {
                if let heading = block.heading {
                    Text(heading)
                        .font(.system(size: fontSize + 1, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.leading, 5)
                        .padding(.top, 4)
                }

                switch block.content {
                case .none:
                    EmptyView()

                case .textBlock(let defaultAttributed, let citations, let isExtract):
                    TextEditor(text: bindingForText(defaultAttributed))
                        .font(.system(size: fontSize))
                        .lineSpacing(4)
                        .scrollDisabled(true)
                        .scrollContentBackground(.hidden)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(isExtract ? 8 : 0)
                        .background(
                            isExtract ? Color.secondary.opacity(0.07) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contextMenu {
                            if !citations.isEmpty {
                                Section("Citations") {
                                    ForEach(citations, id: \.self) { target in
                                        Menu(target.canonicalString) {
                                            Button("Open") { onOpenCitation(target, .currentPane) }
                                            Button("Open in New Tab") { onOpenCitation(target, .newTab) }
                                            Button("Open in Split View") { onOpenCitation(target, .splitPane) }
                                            Button("Open in Separate Window") { onPopOutCitation(target) }
                                        }
                                    }
                                }
                            }
                            Button("Reset Block Text") {
                                if let document {
                                    document.wrappedValue.blockEdits.removeValue(forKey: block.storageKey)
                                } else {
                                    transientEdits.removeValue(forKey: block.storageKey)
                                }
                            }
                        }

                case .table(let node):
                    StatutoryTableView(tableNode: node)
                        .padding(.leading, 5)
                        .padding(.vertical, 4)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 20)
            .padding(.vertical, 6)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            if isAnchorHighlighted {
                Color.accentColor.opacity(0.10)
            } else if isHovered {
                Color.primary.opacity(0.025)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
