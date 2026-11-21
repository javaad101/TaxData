import Foundation
import SQLite3

// MARK: - Section Queries, Hierarchy & FTS5 Search

extension TaxDatabase {
    public func importedSources() -> [ImportedSourceInfo] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT source_id, corpus, title, file_path, imported_at, section_count
            FROM sources ORDER BY corpus ASC, source_id ASC;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [ImportedSourceInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sourceID = columnString(stmt, 0)
            let corpus = CitationTarget.CorpusKind(rawValue: columnString(stmt, 1)) ?? .irc
            let title = columnString(stmt, 2)
            let path = columnOptionalString(stmt, 3)
            let ts = sqlite3_column_double(stmt, 4)
            let count = Int(sqlite3_column_int64(stmt, 5))
            results.append(ImportedSourceInfo(
                sourceID: sourceID,
                corpus: corpus,
                title: title,
                filePath: path,
                importedAt: Date(timeIntervalSince1970: ts),
                sectionCount: count
            ))
        }
        return results
    }

    public func totalSectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("SELECT COUNT(*) FROM sections;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func resolve(_ target: CitationTarget) -> SectionSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
            FROM sections
            WHERE corpus = ? AND number = ? COLLATE NOCASE
            LIMIT 1;
        """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, target.corpus.rawValue)
        bindText(stmt, 2, target.sectionNumber)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readSummaryRow(stmt)
    }

    public func summary(forID id: String) -> SectionSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
            FROM sections WHERE id = ? LIMIT 1;
        """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readSummaryRow(stmt)
    }

    public func summaries(forIDs ids: [String]) -> [SectionSummary] {
        guard !ids.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        guard let stmt = try? prepareUnlocked("""
            SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
            FROM sections WHERE id IN (\(placeholders));
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (idx, id) in ids.enumerated() {
            bindText(stmt, Int32(idx + 1), id)
        }
        var byID: [String: SectionSummary] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let item = readSummaryRow(stmt)
            byID[item.id] = item
        }
        return ids.compactMap { byID[$0] }
    }

    public func allSectionSummaries(sourceID: String? = nil) -> [SectionSummary] {
        lock.lock()
        defer { lock.unlock() }
        let sql: String
        if sourceID != nil {
            sql = """
                SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 480), sort_order
                FROM sections WHERE source_id = ? ORDER BY corpus ASC, sort_order ASC;
            """
        } else {
            sql = """
                SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 480), sort_order
                FROM sections ORDER BY corpus ASC, sort_order ASC;
            """
        }
        guard let stmt = try? prepareUnlocked(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let sourceID {
            bindText(stmt, 1, sourceID)
        }
        var results: [SectionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readSummaryRow(stmt))
        }
        return results
    }

    public func sectionRecord(forID id: String) -> SectionRecord? {
        lock.lock()
        let rawRow: (SectionSummary, String, Data)? = {
            guard let stmt = try? prepareUnlocked("""
                SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order, body_text, node_json
                FROM sections WHERE id = ? LIMIT 1;
            """) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let summary = readSummaryRow(stmt)
            let body = columnString(stmt, 10)
            let blobLen = Int(sqlite3_column_bytes(stmt, 11))
            let data: Data
            if let ptr = sqlite3_column_blob(stmt, 11), blobLen > 0 {
                data = Data(bytes: ptr, count: blobLen)
            } else {
                data = Data()
            }
            return (summary, body, data)
        }()
        lock.unlock()

        guard let (summary, body, jsonData) = rawRow,
              let node = try? JSONDecoder().decode(DocumentNode.self, from: jsonData)
        else { return nil }

        return SectionRecord(summary: summary, bodyText: body, provision: Provision(raw: node))
    }

    /// Combines instant citation detection (`162(a)(2)`, `1.141-1`) with BM25-ranked SQLite FTS5 search.
    public func search(_ rawQuery: String, scope: SearchScope = .all, limit: Int = 60) -> [SearchHit] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var hits: [SearchHit] = []
        var seenIDs = Set<String>()

        // 1. Exact citation resolution first (sub-millisecond)
        if let target = CitationResolver.parse(trimmed) {
            let matchesScope = (scope == .all)
                || (scope == .irc && target.corpus == .irc)
                || (scope == .cfr && target.corpus == .cfr)
            if matchesScope, let exact = resolve(target) {
                seenIDs.insert(exact.id)
                let anchorNote = target.subsectionAnchor.map { "Jumping to (\($0.replacingOccurrences(of: "/", with: ")("))) — " } ?? ""
                hits.append(SearchHit(
                    summary: exact,
                    snippet: anchorNote + exact.previewText,
                    targetAnchor: target.subsectionAnchor,
                    isExactCitationMatch: true
                ))
            }
        }

        // 2. Prefix number match (e.g. typing "1.141" lists § 1.141-0 .. § 1.141-16)
        if !trimmed.contains(" ") {
            let cleanedNum = Provision.normalizeDesignator(trimmed) ?? trimmed
            for summary in prefixNumberMatches(cleanedNum, scope: scope, limit: 12) where seenIDs.insert(summary.id).inserted {
                hits.append(SearchHit(
                    summary: summary,
                    snippet: summary.previewText,
                    targetAnchor: nil,
                    isExactCitationMatch: false
                ))
            }
        }

        // 3. FTS5 BM25 ranked search with highlighted snippets
        if let ftsQuery = Self.buildFTSQuery(from: trimmed) {
            lock.lock()
            let ftsHits: [SearchHit] = {
                let scopeClause = scope == .all ? "" : "AND sections_fts.corpus = ?"
                let sql = """
                    SELECT s.id, s.source_id, s.corpus, s.number, s.display_title, s.heading, s.breadcrumb, s.parent_irc, substr(s.body_text, 1, 320), s.sort_order,
                           snippet(sections_fts, 5, '«', '»', '…', 26)
                    FROM sections_fts
                    JOIN sections s ON s.id = sections_fts.id
                    WHERE sections_fts MATCH ? \(scopeClause)
                    ORDER BY bm25(sections_fts, 0.0, 0.0, 12.0, 8.0, 2.0, 1.0)
                    LIMIT ?;
                """
                guard let stmt = try? prepareUnlocked(sql) else { return [] }
                defer { sqlite3_finalize(stmt) }
                var paramIdx: Int32 = 1
                bindText(stmt, paramIdx, ftsQuery)
                paramIdx += 1
                if scope != .all {
                    bindText(stmt, paramIdx, scope == .irc ? "IRC" : "CFR")
                    paramIdx += 1
                }
                sqlite3_bind_int64(stmt, paramIdx, sqlite3_int64(limit))

                var rows: [SearchHit] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let summary = readSummaryRow(stmt)
                    let snippet = columnString(stmt, 10)
                    rows.append(SearchHit(
                        summary: summary,
                        snippet: snippet.isEmpty ? summary.previewText : snippet,
                        targetAnchor: nil,
                        isExactCitationMatch: false
                    ))
                }
                return rows
            }()
            lock.unlock()

            for hit in ftsHits where seenIDs.insert(hit.id).inserted {
                hits.append(hit)
                if hits.count >= limit { break }
            }
        }

        return hits
    }

    public func relatedRegulations(forIRCSection ircNumber: String) -> [SectionSummary] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
            FROM sections
            WHERE corpus = 'CFR' AND parent_irc = ? COLLATE NOCASE
            ORDER BY sort_order ASC;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, ircNumber)
        var results: [SectionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readSummaryRow(stmt))
        }
        return results
    }

    public func adjacentSections(around summary: SectionSummary) -> (previous: SectionSummary?, next: SectionSummary?) {
        lock.lock()
        defer { lock.unlock() }

        let prev: SectionSummary? = {
            guard let stmt = try? prepareUnlocked("""
                SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
                FROM sections
                WHERE corpus = ? AND sort_order < ?
                ORDER BY sort_order DESC LIMIT 1;
            """) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, summary.corpus.rawValue)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(summary.sortOrder))
            return sqlite3_step(stmt) == SQLITE_ROW ? readSummaryRow(stmt) : nil
        }()

        let next: SectionSummary? = {
            guard let stmt = try? prepareUnlocked("""
                SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
                FROM sections
                WHERE corpus = ? AND sort_order > ?
                ORDER BY sort_order ASC LIMIT 1;
            """) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, summary.corpus.rawValue)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(summary.sortOrder))
            return sqlite3_step(stmt) == SQLITE_ROW ? readSummaryRow(stmt) : nil
        }()

        return (prev, next)
    }

    public func hierarchyGroups(for corpus: CitationTarget.CorpusKind) -> [HierarchyGroup] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 200), sort_order
            FROM sections
            WHERE corpus = ?
            ORDER BY sort_order ASC;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, corpus.rawValue)

        var groups: [HierarchyGroup] = []
        var indexByCrumb: [String: Int] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let item = readSummaryRow(stmt)
            let crumb = item.breadcrumb.isEmpty ? (corpus == .irc ? "Internal Revenue Code" : "Treasury Regulations") : item.breadcrumb
            if let idx = indexByCrumb[crumb] {
                groups[idx].sections.append(item)
            } else {
                indexByCrumb[crumb] = groups.count
                groups.append(HierarchyGroup(corpus: corpus, breadcrumb: crumb, sections: [item]))
            }
        }
        return groups
    }

    private func prefixNumberMatches(_ numberPrefix: String, scope: SearchScope, limit: Int) -> [SectionSummary] {
        guard numberPrefix.first?.isNumber == true else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let scopeSQL = scope == .all ? "" : "AND corpus = ?"
        guard let stmt = try? prepareUnlocked("""
            SELECT id, source_id, corpus, number, display_title, heading, breadcrumb, parent_irc, substr(body_text, 1, 320), sort_order
            FROM sections
            WHERE (number LIKE ? OR parent_irc = ? COLLATE NOCASE) \(scopeSQL)
            ORDER BY corpus ASC, sort_order ASC
            LIMIT ?;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        bindText(stmt, idx, "\(numberPrefix)%"); idx += 1
        bindText(stmt, idx, numberPrefix); idx += 1
        if scope != .all {
            bindText(stmt, idx, scope == .irc ? "IRC" : "CFR"); idx += 1
        }
        sqlite3_bind_int64(stmt, idx, sqlite3_int64(limit))

        var out: [SectionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(readSummaryRow(stmt))
        }
        return out
    }

    internal static func buildFTSQuery(from raw: String) -> String? {
        var phrases: [String] = []
        var cursor = raw.startIndex
        var outside = ""

        while cursor < raw.endIndex {
            if raw[cursor] == "\"" {
                let afterOpen = raw.index(after: cursor)
                if let close = raw[afterOpen...].firstIndex(of: "\"") {
                    let phrase = raw[afterOpen..<close]
                        .replacingOccurrences(of: "\"", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !phrase.isEmpty {
                        phrases.append("\"\(phrase)\"")
                    }
                    cursor = raw.index(after: close)
                    continue
                }
            }
            outside.append(raw[cursor])
            cursor = raw.index(after: cursor)
        }

        let rawTokens = outside
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var clauses: [String] = phrases
        var i = 0
        while i < rawTokens.count {
            let tok = rawTokens[i]
            let upper = tok.uppercased()
            if (upper == "OR" || upper == "NOT" || upper == "AND"), !clauses.isEmpty, i + 1 < rawTokens.count {
                clauses.append(upper)
            } else if i == rawTokens.count - 1 && tok.count >= 2 {
                clauses.append("\(tok)*")
            } else {
                clauses.append("\"\(tok)\"")
            }
            i += 1
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " ")
    }
}
