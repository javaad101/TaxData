import Foundation
import SQLite3

// MARK: - XML Corpus Ingestion Pipeline

extension TaxDatabase {
    /// Parses and indexes a USLM (`.xml`) or CFR/eCFR (`.xml`) file into SQLite + FTS5 in a single transaction.
    @discardableResult
    public func importXMLFile(at url: URL, sourceID customSourceID: String? = nil) throws -> ImportedSourceInfo {
        let root = try DocumentNode.parseXML(contentsOf: url)
        let sourceID = customSourceID ?? url.lastPathComponent
        return try importDocument(root: root, sourceID: sourceID, filePath: url.path)
    }

    @discardableResult
    public func importDocument(
        root: DocumentNode,
        sourceID: String,
        filePath: String? = nil
    ) throws -> ImportedSourceInfo {
        let isUSLM = root.key == "uscDoc" || root.firstElement(forKey: "section", recursive: true) != nil
        let corpus: CitationTarget.CorpusKind = isUSLM ? .irc : .cfr

        let docNumber = root.firstElement(forKey: "docNumber", recursive: true)?.normalizedText
        let cfrTitleNum = root.firstElement(forKey: "TITLENUM", recursive: true)?.normalizedText
            ?? root.firstElement(forKey: "IDNO", recursive: true)?.normalizedText
        let partsDesc = root.firstElement(forKey: "PARTS", recursive: true)?.normalizedText

        let sourceTitle: String
        if isUSLM {
            let mainHeading = root.firstElement(forKey: "title", recursive: true)?
                .firstElement(forKey: "heading")?.normalizedText
            sourceTitle = [
                root.firstElement(forKey: "dc:title", recursive: true)?.normalizedText,
                mainHeading,
            ].compactMap { $0 }.joined(separator: " — ")
        } else {
            sourceTitle = [cfrTitleNum.map { $0.contains("CFR") ? $0 : "Title \($0) CFR" } ?? "26 CFR", partsDesc ?? sourceID]
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
        }

        let citationPrefix: String
        if isUSLM {
            citationPrefix = (docNumber == nil || docNumber == "26") ? "IRC §" : "\(docNumber!) U.S.C. §"
        } else {
            let isTitle26 = cfrTitleNum == nil || cfrTitleNum?.contains("26") == true
            citationPrefix = isTitle26 ? "Treas. Reg. §" : "C.F.R. §"
        }

        struct PendingRow {
            var id: String
            var number: String
            var displayTitle: String
            var heading: String
            var breadcrumb: String
            var parentIRC: String?
            var bodyText: String
            var nodeJSON: Data
            var sortOrder: Int
        }

        let encoder = JSONEncoder()
        var pending: [PendingRow] = []
        let volumeNumber = Self.extractVolumeOrder(from: sourceID)
        var counter = volumeNumber * 100_000

        func walk(node: DocumentNode, ancestors: [String]) throws {
            guard node.key != "quotedContent" else { return }

            var nextAncestors = ancestors
            if Provision.structuralKeys.contains(node.key) && !Provision.isSection(node) {
                let prov = Provision(raw: node)
                let tierKind = prov.kind
                if tierKind != "title" {
                    let num = prov.number?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let head = prov.heading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let label: String
                    if !head.isEmpty && (
                        head.localizedCaseInsensitiveContains("chapter ")
                        || head.localizedCaseInsensitiveContains("subchapter ")
                        || head.localizedCaseInsensitiveContains("part ")
                        || head.localizedCaseInsensitiveContains("subpart ")
                        || head.localizedCaseInsensitiveContains("subtitle ")
                    ) {
                        label = head
                    } else {
                        label = [num, head].filter { !$0.isEmpty }.joined(separator: " ")
                    }
                    if !label.isEmpty {
                        nextAncestors.append(label)
                    }
                }
            }

            if Provision.isSection(node) {
                let prov = Provision(raw: node)
                let rawNum = prov.value ?? prov.number ?? ""
                let number = Provision.normalizeDesignator(rawNum) ?? rawNum
                guard !number.isEmpty else { return }

                counter += 1
                let id: String
                if corpus == .irc {
                    id = prov.identifier ?? "/us/usc/t\(docNumber ?? "26")/s\(number)"
                } else {
                    id = "cfr:26:\(number)"
                }

                let displayTitle = "\(citationPrefix) \(number)"
                let heading = prov.heading ?? ""
                let breadcrumb = nextAncestors.joined(separator: " › ")
                let parentIRC = corpus == .cfr ? CitationResolver.parentIRCSection(forCFRNumber: number) : nil
                let body = prov.bodyText
                let json = try encoder.encode(node)

                pending.append(PendingRow(
                    id: id,
                    number: number,
                    displayTitle: displayTitle,
                    heading: heading,
                    breadcrumb: breadcrumb,
                    parentIRC: parentIRC,
                    bodyText: body,
                    nodeJSON: json,
                    sortOrder: counter
                ))
                return
            }

            for child in node.children {
                if case .element(let childElem) = child {
                    try walk(node: childElem, ancestors: nextAncestors)
                }
            }
        }

        try walk(node: root, ancestors: [])
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteSourceUnlocked(sourceID: sourceID)

            let deleteExistingFTS = try prepareUnlocked("DELETE FROM sections_fts WHERE id = ?;")
            defer { sqlite3_finalize(deleteExistingFTS) }

            let insertSection = try prepareUnlocked("""
                INSERT OR REPLACE INTO sections
                (id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, body_text, node_json, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insertSection) }

            let insertFTS = try prepareUnlocked("""
                INSERT INTO sections_fts (id, corpus, display_title, heading, breadcrumb, body_text)
                VALUES (?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insertFTS) }

            for row in pending {
                sqlite3_reset(deleteExistingFTS)
                bindText(deleteExistingFTS, 1, row.id)
                try stepDoneUnlocked(deleteExistingFTS)

                sqlite3_reset(insertSection)
                bindText(insertSection, 1, row.id)
                bindText(insertSection, 2, sourceID)
                bindText(insertSection, 3, corpus.rawValue)
                bindText(insertSection, 4, row.number)
                bindText(insertSection, 5, row.displayTitle)
                bindText(insertSection, 6, row.heading)
                bindText(insertSection, 7, row.breadcrumb)
                bindOptionalText(insertSection, 8, row.parentIRC)
                bindText(insertSection, 9, row.bodyText)
                bindBlob(insertSection, 10, row.nodeJSON)
                sqlite3_bind_int64(insertSection, 11, sqlite3_int64(row.sortOrder))
                try stepDoneUnlocked(insertSection)

                sqlite3_reset(insertFTS)
                bindText(insertFTS, 1, row.id)
                bindText(insertFTS, 2, corpus.rawValue)
                bindText(insertFTS, 3, row.displayTitle)
                bindText(insertFTS, 4, row.heading)
                bindText(insertFTS, 5, row.breadcrumb)
                bindText(insertFTS, 6, row.bodyText)
                try stepDoneUnlocked(insertFTS)
            }

            let insertSource = try prepareUnlocked("""
                INSERT OR REPLACE INTO sources (source_id, corpus, title, file_path, imported_at, section_count)
                VALUES (?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insertSource) }
            bindText(insertSource, 1, sourceID)
            bindText(insertSource, 2, corpus.rawValue)
            bindText(insertSource, 3, sourceTitle.isEmpty ? sourceID : sourceTitle)
            bindOptionalText(insertSource, 4, filePath)
            sqlite3_bind_double(insertSource, 5, now.timeIntervalSince1970)
            sqlite3_bind_int64(insertSource, 6, sqlite3_int64(pending.count))
            try stepDoneUnlocked(insertSource)

            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }

        return ImportedSourceInfo(
            sourceID: sourceID,
            corpus: corpus,
            title: sourceTitle.isEmpty ? sourceID : sourceTitle,
            filePath: filePath,
            importedAt: now,
            sectionCount: pending.count
        )
    }

    public func removeSource(_ sourceID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try deleteSourceUnlocked(sourceID: sourceID)
            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }
    }

    internal func deleteSourceUnlocked(sourceID: String) throws {
        let delFTS = try prepareUnlocked("DELETE FROM sections_fts WHERE id IN (SELECT id FROM sections WHERE source_id = ?);")
        defer { sqlite3_finalize(delFTS) }
        bindText(delFTS, 1, sourceID)
        try stepDoneUnlocked(delFTS)

        let delSecs = try prepareUnlocked("DELETE FROM sections WHERE source_id = ?;")
        defer { sqlite3_finalize(delSecs) }
        bindText(delSecs, 1, sourceID)
        try stepDoneUnlocked(delSecs)

        let delSrc = try prepareUnlocked("DELETE FROM sources WHERE source_id = ?;")
        defer { sqlite3_finalize(delSrc) }
        bindText(delSrc, 1, sourceID)
        try stepDoneUnlocked(delSrc)
    }

    private static func extractVolumeOrder(from sourceID: String) -> Int {
        if let range = sourceID.range(of: #"vol(\d+)"#, options: [.regularExpression, .caseInsensitive]) {
            let digits = sourceID[range].drop { !$0.isNumber }
            return Int(digits) ?? 0
        }
        return 0
    }
}
