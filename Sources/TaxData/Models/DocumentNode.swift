import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A schema-agnostic, lossless, recursive key-value representation of hierarchical documents
/// such as USLM XML (U.S. Code), eCFR XML (Treasury Regulations), and arbitrary JSON.
///
/// Every node consists of:
/// - `key`: The tag or property name (e.g., `"section"`, `"DIV8"`, `"heading"`, `"P"`).
/// - `attributes`: Key-value string attributes from the source element (e.g., `"identifier"`, `"N"`).
/// - `children`: Ordered sequence of text runs and child elements, preserving mixed-content order.
///
/// Because structure and inline text order are preserved without schema-specific types,
/// callers can inspect and query nodes purely by key across different legal/regulatory schemas.
public struct DocumentNode: Sendable, Hashable, Codable {
    /// Ordered child content inside an element, preserving interleaved text and child elements.
    public enum Content: Sendable, Hashable, Codable {
        case text(String)
        case element(DocumentNode)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            self = .element(try container.decode(DocumentNode.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value):
                try container.encode(value)
            case .element(let node):
                try container.encode(node)
            }
        }
    }

    public var key: String
    public var attributes: [String: String]
    public var children: [Content]

    public init(
        key: String,
        attributes: [String: String] = [:],
        children: [Content] = []
    ) {
        self.key = key
        self.attributes = attributes
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case attributes
        case children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        self.children = try container.decodeIfPresent([Content].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if !attributes.isEmpty {
            try container.encode(attributes, forKey: .attributes)
        }
        if !children.isEmpty {
            try container.encode(children, forKey: .children)
        }
    }
}

// MARK: - Recursive & Key-Value Query API

extension DocumentNode {
    /// Direct child elements in document order.
    public var elements: [DocumentNode] {
        var result: [DocumentNode] = []
        for child in children {
            if case .element(let node) = child {
                result.append(node)
            }
        }
        return result
    }

    /// Concatenation of direct `.text` children on this node only (excluding descendants).
    public var directText: String {
        var buffer = ""
        for child in children {
            if case .text(let chunk) = child {
                buffer.append(chunk)
            }
        }
        return buffer
    }

    /// Depth-first concatenation of all `.text` leaves under this node in exact document order.
    public var text: String {
        var buffer = ""
        appendText(into: &buffer)
        return buffer
    }

    /// `text` with leading and trailing whitespace and newlines trimmed.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` with contiguous whitespace runs collapsed to a single space
    /// and leading/trailing whitespace trimmed.
    public var normalizedText: String {
        Self.collapseWhitespace(text)
    }

    internal static func collapseWhitespace(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var pendingSpace = false

        for ch in raw {
            if ch.isWhitespace {
                if !result.isEmpty {
                    pendingSpace = true
                }
            } else {
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.append(ch)
            }
        }
        return result
    }

    /// Distinct keys present directly on this node: sorted attribute keys followed by
    /// direct child element keys in order of first appearance.
    public var keys: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for attrKey in attributes.keys.sorted() {
            if seen.insert(attrKey).inserted {
                ordered.append(attrKey)
            }
        }
        for child in children {
            if case .element(let node) = child, seen.insert(node.key).inserted {
                ordered.append(node.key)
            }
        }
        return ordered
    }

    /// Direct child elements grouped by their `key`, preserving document order within each group.
    public var groupedElements: [String: [DocumentNode]] {
        var grouped: [String: [DocumentNode]] = [:]
        for child in children {
            if case .element(let node) = child {
                grouped[node.key, default: []].append(node)
            }
        }
        return grouped
    }

    /// Direct child elements whose `key` matches `key`.
    public subscript(_ key: String) -> [DocumentNode] {
        var matches: [DocumentNode] = []
        for child in children {
            if case .element(let node) = child, node.key == key {
                matches.append(node)
            }
        }
        return matches
    }

    /// Direct attribute value for `key`, if present.
    public subscript(attribute key: String) -> String? {
        attributes[key]
    }

    /// Returns the first string associated with `key`, checking `attributes[key]` first
    /// and then child elements whose `key` matches (returning `child.text`).
    ///
    /// When `recursive` is `true`, searches descendants depth-first in document order.
    public func string(forKey key: String, recursive: Bool = false) -> String? {
        if let value = attributes[key] {
            return value
        }
        for child in children {
            guard case .element(let node) = child else { continue }
            if node.key == key {
                return node.text
            }
            if recursive, let nested = node.string(forKey: key, recursive: true) {
                return nested
            }
        }
        return nil
    }

    /// Returns all strings associated with `key` (both attributes and matching elements' `.text`),
    /// optionally searching descendants depth-first in document order.
    public func strings(forKey key: String, recursive: Bool = false) -> [String] {
        var results: [String] = []
        if recursive {
            appendStrings(forKey: key, into: &results)
        } else {
            if let value = attributes[key] {
                results.append(value)
            }
            for child in children {
                if case .element(let node) = child, node.key == key {
                    results.append(node.text)
                }
            }
        }
        return results
    }

    /// Returns child elements matching `key` in document order,
    /// optionally searching all descendants recursively.
    public func elements(forKey key: String, recursive: Bool = false) -> [DocumentNode] {
        guard recursive else { return self[key] }
        return descendants { $0.key == key }
    }

    /// Returns the first element matching `key` in document order,
    /// optionally searching descendants depth-first.
    public func firstElement(forKey key: String, recursive: Bool = false) -> DocumentNode? {
        if !recursive {
            for child in children {
                if case .element(let node) = child, node.key == key {
                    return node
                }
            }
            return nil
        }
        return firstDescendant { $0.key == key }
    }

    /// Pre-order depth-first traversal starting with `self`.
    public func walk(_ visit: (DocumentNode) throws -> Void) rethrows {
        try visit(self)
        for child in children {
            if case .element(let node) = child {
                try node.walk(visit)
            }
        }
    }

    /// Returns all descendant elements matching `predicate` in pre-order document order
    /// (excluding `self`).
    public func descendants(where predicate: (DocumentNode) throws -> Bool) rethrows -> [DocumentNode] {
        var results: [DocumentNode] = []
        try collectDescendants(where: predicate, into: &results)
        return results
    }

    /// Returns the first descendant element matching `predicate` in pre-order depth-first order
    /// (excluding `self`).
    public func firstDescendant(where predicate: (DocumentNode) throws -> Bool) rethrows -> DocumentNode? {
        for child in children {
            guard case .element(let node) = child else { continue }
            if try predicate(node) {
                return node
            }
            if let match = try node.firstDescendant(where: predicate) {
                return match
            }
        }
        return nil
    }

    /// Finds the first descendant element with `key` where `attributes[attrKey] == value`.
    public func firstElement(
        forKey key: String,
        whereAttribute attrKey: String,
        equals value: String
    ) -> DocumentNode? {
        firstDescendant { $0.key == key && $0.attributes[attrKey] == value }
    }

    private func appendText(into buffer: inout String) {
        for child in children {
            switch child {
            case .text(let chunk):
                buffer.append(chunk)
            case .element(let node):
                node.appendText(into: &buffer)
            }
        }
    }

    private func appendStrings(forKey key: String, into results: inout [String]) {
        if let value = attributes[key] {
            results.append(value)
        }
        for child in children {
            guard case .element(let node) = child else { continue }
            if node.key == key {
                results.append(node.text)
            }
            node.appendStrings(forKey: key, into: &results)
        }
    }

    private func collectDescendants(
        where predicate: (DocumentNode) throws -> Bool,
        into results: inout [DocumentNode]
    ) rethrows {
        for child in children {
            guard case .element(let node) = child else { continue }
            if try predicate(node) {
                results.append(node)
            }
            try node.collectDescendants(where: predicate, into: &results)
        }
    }
}

// MARK: - Errors

public enum DocumentParseError: Error, Sendable, LocalizedError {
    case invalidXML(message: String, line: Int, column: Int)
    case emptyDocument
    case unreadableInput(String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidXML(let message, let line, let column):
            return "Invalid XML at line \(line), column \(column): \(message)"
        case .emptyDocument:
            return "XML document contained no root element."
        case .unreadableInput(let detail):
            return "Unable to read input: \(detail)"
        case .invalidJSON(let detail):
            return "Invalid JSON: \(detail)"
        }
    }
}

// MARK: - XML Parsing & Streaming

extension DocumentNode {
    /// Parses a complete XML document from raw `Data`, preserving all text order and attributes.
    public static func parseXML(data: Data) throws -> DocumentNode {
        let parser = XMLParser(data: data)
        return try runFullXMLParser(parser)
    }

    /// Parses a complete XML document from a `String`.
    public static func parseXML(string: String) throws -> DocumentNode {
        try parseXML(data: Data(string.utf8))
    }

    /// Parses a complete XML document directly from a file `URL` via `InputStream`.
    public static func parseXML(contentsOf url: URL) throws -> DocumentNode {
        guard let stream = InputStream(url: url) else {
            throw DocumentParseError.unreadableInput(url.path)
        }
        let parser = XMLParser(stream: stream)
        return try runFullXMLParser(parser)
    }

    /// Streams an XML file from disk, invoking `handler` for each outermost element whose `key`
    /// matches `key`. Memory stays bounded to a single matched subtree rather than the whole file.
    public static func streamXML(
        contentsOf url: URL,
        matchingKey key: String,
        handler: (DocumentNode) throws -> Void
    ) throws {
        try streamXML(contentsOf: url, matching: { elementKey, _ in elementKey == key }, handler: handler)
    }

    /// Streams an XML file from disk, invoking `handler` for each outermost element satisfying `predicate`.
    public static func streamXML(
        contentsOf url: URL,
        matching predicate: (_ key: String, _ attributes: [String: String]) -> Bool,
        handler: (DocumentNode) throws -> Void
    ) throws {
        guard let stream = InputStream(url: url) else {
            throw DocumentParseError.unreadableInput(url.path)
        }
        let parser = XMLParser(stream: stream)
        try runStreamingXMLParser(parser, matching: predicate, handler: handler)
    }

    /// Streams XML `Data`, invoking `handler` for each outermost element whose `key` matches `key`.
    public static func streamXML(
        data: Data,
        matchingKey key: String,
        handler: (DocumentNode) throws -> Void
    ) throws {
        try streamXML(data: data, matching: { elementKey, _ in elementKey == key }, handler: handler)
    }

    /// Streams XML `Data`, invoking `handler` for each outermost element satisfying `predicate`.
    public static func streamXML(
        data: Data,
        matching predicate: (_ key: String, _ attributes: [String: String]) -> Bool,
        handler: (DocumentNode) throws -> Void
    ) throws {
        let parser = XMLParser(data: data)
        try runStreamingXMLParser(parser, matching: predicate, handler: handler)
    }

    private static func configureXMLParser(_ parser: XMLParser) {
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
    }

    private static func runFullXMLParser(_ parser: XMLParser) throws -> DocumentNode {
        configureXMLParser(parser)
        var root: DocumentNode?
        let delegate = XMLTreeDelegate(startPredicate: nil) { node in
            root = node
        }
        parser.delegate = delegate

        let succeeded = parser.parse()
        if !succeeded {
            throw delegate.reportedError(from: parser)
        }
        guard let root else {
            throw DocumentParseError.emptyDocument
        }
        return root
    }

    private static func runStreamingXMLParser(
        _ parser: XMLParser,
        matching predicate: (_ key: String, _ attributes: [String: String]) -> Bool,
        handler: (DocumentNode) throws -> Void
    ) throws {
        configureXMLParser(parser)
        var capturedHandlerError: Error?
        var parseFailure: DocumentParseError?

        withoutActuallyEscaping(predicate) { escapingPredicate in
            withoutActuallyEscaping(handler) { escapingHandler in
                let delegate = XMLTreeDelegate(startPredicate: escapingPredicate) { node in
                    do {
                        try escapingHandler(node)
                    } catch {
                        capturedHandlerError = error
                        parser.abortParsing()
                    }
                }
                parser.delegate = delegate
                let succeeded = parser.parse()
                parser.delegate = nil
                if !succeeded {
                    parseFailure = delegate.reportedError(from: parser)
                }
            }
        }

        if let capturedHandlerError {
            throw capturedHandlerError
        }
        if let parseFailure {
            throw parseFailure
        }
    }
}

private struct XMLFrame {
    var node: DocumentNode
    var pendingText: String = ""

    mutating func flushPendingText() {
        if !pendingText.isEmpty {
            node.children.append(.text(pendingText))
            pendingText = ""
        }
    }
}

private final class XMLTreeDelegate: NSObject, XMLParserDelegate {
    private let startPredicate: ((_ key: String, _ attributes: [String: String]) -> Bool)?
    private let onComplete: (DocumentNode) -> Void
    private var stack: [XMLFrame] = []
    private var parseError: Error?
    private var errorLine: Int = 0
    private var errorColumn: Int = 0

    init(
        startPredicate: ((_ key: String, _ attributes: [String: String]) -> Bool)?,
        onComplete: @escaping (DocumentNode) -> Void
    ) {
        self.startPredicate = startPredicate
        self.onComplete = onComplete
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if stack.isEmpty {
            if let startPredicate, !startPredicate(elementName, attributeDict) {
                return
            }
        } else {
            stack[stack.count - 1].flushPendingText()
        }
        stack.append(XMLFrame(node: DocumentNode(key: elementName, attributes: attributeDict)))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].pendingText.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].pendingText.append(text)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !stack.isEmpty else { return }
        var finished = stack.removeLast()
        finished.flushPendingText()

        if stack.isEmpty {
            onComplete(finished.node)
        } else {
            stack[stack.count - 1].node.children.append(.element(finished.node))
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
        self.errorLine = parser.lineNumber
        self.errorColumn = parser.columnNumber
    }

    func reportedError(from parser: XMLParser) -> DocumentParseError {
        let error = parseError ?? parser.parserError
        let message = error?.localizedDescription ?? "Unknown XML parse failure"
        let line = errorLine != 0 ? errorLine : parser.lineNumber
        let column = errorColumn != 0 ? errorColumn : parser.columnNumber
        return .invalidXML(message: message, line: line, column: column)
    }
}

// MARK: - Arbitrary JSON Ingestion

extension DocumentNode {
    /// Converts arbitrary JSON `Data` into a recursive `DocumentNode` tree keyed by property name.
    public static func parseJSON(data: Data, rootKey: String = "root") throws -> DocumentNode {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DocumentParseError.invalidJSON(error.localizedDescription)
        }
        return buildJSONNode(key: rootKey, value: object)
    }

    /// Loads arbitrary JSON from a file `URL` into a recursive `DocumentNode` tree.
    public static func parseJSON(contentsOf url: URL, rootKey: String = "root") throws -> DocumentNode {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DocumentParseError.unreadableInput("\(url.path): \(error.localizedDescription)")
        }
        return try parseJSON(data: data, rootKey: rootKey)
    }

    private static func buildJSONNode(key: String, value: Any) -> DocumentNode {
        if let dict = value as? [String: Any] {
            var children: [Content] = []
            for childKey in dict.keys.sorted() {
                guard let childValue = dict[childKey] else { continue }
                if let array = childValue as? [Any] {
                    for item in array {
                        children.append(.element(buildJSONNode(key: childKey, value: item)))
                    }
                } else {
                    children.append(.element(buildJSONNode(key: childKey, value: childValue)))
                }
            }
            return DocumentNode(key: key, children: children)
        }

        if let array = value as? [Any] {
            let children: [Content] = array.map { .element(buildJSONNode(key: "item", value: $0)) }
            return DocumentNode(key: key, children: children)
        }

        if let str = value as? String {
            return DocumentNode(key: key, children: [.text(str)])
        }

        if let num = value as? NSNumber {
            #if canImport(CoreFoundation)
            let isBool = CFGetTypeID(num) == CFBooleanGetTypeID()
            #else
            let isBool = type(of: num) == type(of: NSNumber(value: true))
            #endif
            let text = isBool ? (num.boolValue ? "true" : "false") : num.stringValue
            return DocumentNode(key: key, children: [.text(text)])
        }

        if value is NSNull {
            return DocumentNode(key: key)
        }

        return DocumentNode(key: key, children: [.text(String(describing: value))])
    }
}
