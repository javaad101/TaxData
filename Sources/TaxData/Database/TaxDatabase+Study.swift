import Foundation
import SQLite3

// MARK: - Course Pinboards, Personal Notes & History

extension TaxDatabase {
    internal func seedDefaultCourseFoldersIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let checkStmt = try? prepareUnlocked("SELECT COUNT(*) FROM bookmark_folders;") else { return }
        defer { sqlite3_finalize(checkStmt) }
        let existingCount = sqlite3_step(checkStmt) == SQLITE_ROW ? Int(sqlite3_column_int64(checkStmt, 0)) : 0
        guard existingCount == 0 else { return }

        let defaults: [(String, String, String, Int)] = [
            ("general", "Starred Provisions", "star.fill", 0),
            ("corp610", "Corporate Tax (610)", "building.2.fill", 1),
            ("part620", "Partnership Tax (620)", "person.2.fill", 2),
            ("fed640", "Federal Income Tax (640)", "dollarsign.circle.fill", 3),
            ("intl670", "International Tax (670)", "globe.americas.fill", 4),
            ("proc675", "IRS Practice & Proc (675)", "checkmark.shield.fill", 5),
        ]

        let insert = try prepareUnlocked("""
            INSERT OR IGNORE INTO bookmark_folders (id, name, icon, sort_order)
            VALUES (?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(insert) }

        for (id, name, icon, order) in defaults {
            sqlite3_reset(insert)
            bindText(insert, 1, id)
            bindText(insert, 2, name)
            bindText(insert, 3, icon)
            sqlite3_bind_int64(insert, 4, sqlite3_int64(order))
            try stepDoneUnlocked(insert)
        }
    }

    // MARK: - Course Pinboards & Bookmarks

    public func bookmarkFolders() -> [BookmarkFolder] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT id, name, icon, sort_order FROM bookmark_folders ORDER BY sort_order ASC, name ASC;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [BookmarkFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(BookmarkFolder(
                id: columnString(stmt, 0),
                name: columnString(stmt, 1),
                icon: columnString(stmt, 2),
                sortOrder: Int(sqlite3_column_int64(stmt, 3))
            ))
        }
        return out
    }

    @discardableResult
    public func createBookmarkFolder(name: String, icon: String = "folder.fill") throws -> BookmarkFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "custom-" + UUID().uuidString.lowercased()
        lock.lock()
        defer { lock.unlock() }

        let nextOrder: Int = {
            guard let s = try? prepareUnlocked("SELECT COALESCE(MAX(sort_order), 0) + 1 FROM bookmark_folders;") else { return 10 }
            defer { sqlite3_finalize(s) }
            return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 10
        }()

        let stmt = try prepareUnlocked("INSERT INTO bookmark_folders (id, name, icon, sort_order) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        bindText(stmt, 2, trimmed)
        bindText(stmt, 3, icon)
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(nextOrder))
        try stepDoneUnlocked(stmt)

        return BookmarkFolder(id: id, name: trimmed, icon: icon, sortOrder: nextOrder)
    }

    public func deleteBookmarkFolder(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let delB = try prepareUnlocked("DELETE FROM bookmarks WHERE folder_id = ?;")
        defer { sqlite3_finalize(delB) }
        bindText(delB, 1, id)
        try stepDoneUnlocked(delB)

        let delF = try prepareUnlocked("DELETE FROM bookmark_folders WHERE id = ?;")
        defer { sqlite3_finalize(delF) }
        bindText(delF, 1, id)
        try stepDoneUnlocked(delF)
    }

    public func bookmarkedFolderIDs(for sectionID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("SELECT DISTINCT folder_id FROM bookmarks WHERE section_id = ?;") else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sectionID)
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(columnString(stmt, 0))
        }
        return out
    }

    public func toggleBookmark(sectionID: String, folderID: String, anchor: String? = nil) throws {
        let normalizedAnchor = anchor ?? ""
        lock.lock()
        defer { lock.unlock() }

        let exists: Bool = {
            guard let s = try? prepareUnlocked("""
                SELECT 1 FROM bookmarks WHERE section_id = ? AND folder_id = ? AND anchor = ? LIMIT 1;
            """) else { return false }
            defer { sqlite3_finalize(s) }
            bindText(s, 1, sectionID)
            bindText(s, 2, folderID)
            bindText(s, 3, normalizedAnchor)
            return sqlite3_step(s) == SQLITE_ROW
        }()

        if exists {
            let del = try prepareUnlocked("DELETE FROM bookmarks WHERE section_id = ? AND folder_id = ? AND anchor = ?;")
            defer { sqlite3_finalize(del) }
            bindText(del, 1, sectionID)
            bindText(del, 2, folderID)
            bindText(del, 3, normalizedAnchor)
            try stepDoneUnlocked(del)
        } else {
            let ins = try prepareUnlocked("""
                INSERT OR REPLACE INTO bookmarks (section_id, folder_id, anchor, created_at)
                VALUES (?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(ins) }
            bindText(ins, 1, sectionID)
            bindText(ins, 2, folderID)
            bindText(ins, 3, normalizedAnchor)
            sqlite3_bind_double(ins, 4, Date().timeIntervalSince1970)
            try stepDoneUnlocked(ins)
        }
    }

    public func bookmarks(inFolder folderID: String? = nil) -> [BookmarkEntry] {
        lock.lock()
        defer { lock.unlock() }
        let filterClause = folderID == nil ? "" : "WHERE b.folder_id = ?"
        guard let stmt = try? prepareUnlocked("""
            SELECT s.id, s.source_id, s.corpus, s.number, s.display_title, s.heading, s.breadcrumb, s.parent_irc, substr(s.body_text, 1, 320), s.sort_order,
                   b.folder_id, b.anchor, b.created_at
            FROM bookmarks b
            JOIN sections s ON s.id = b.section_id
            \(filterClause)
            ORDER BY b.created_at DESC;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let folderID {
            bindText(stmt, 1, folderID)
        }

        var out: [BookmarkEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let summary = readSummaryRow(stmt)
            let fID = columnString(stmt, 10)
            let rawAnchor = columnString(stmt, 11)
            let ts = sqlite3_column_double(stmt, 12)
            out.append(BookmarkEntry(
                folderID: fID,
                summary: summary,
                anchor: rawAnchor.isEmpty ? nil : rawAnchor,
                createdAt: Date(timeIntervalSince1970: ts)
            ))
        }
        return out
    }

    // MARK: - Personal Exam Notes

    public func userNote(for sectionID: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("SELECT content FROM user_notes WHERE section_id = ? LIMIT 1;") else { return "" }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sectionID)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnString(stmt, 0) : ""
    }

    public func saveUserNote(_ content: String, for sectionID: String) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if trimmed.isEmpty {
            let del = try prepareUnlocked("DELETE FROM user_notes WHERE section_id = ?;")
            defer { sqlite3_finalize(del) }
            bindText(del, 1, sectionID)
            try stepDoneUnlocked(del)
        } else {
            let up = try prepareUnlocked("""
                INSERT OR REPLACE INTO user_notes (section_id, content, updated_at)
                VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(up) }
            bindText(up, 1, sectionID)
            bindText(up, 2, content)
            sqlite3_bind_double(up, 3, Date().timeIntervalSince1970)
            try stepDoneUnlocked(up)
        }
    }

    public func allAnnotatedSections() -> [AnnotatedSection] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT s.id, s.source_id, s.corpus, s.number, s.display_title, s.heading, s.breadcrumb, s.parent_irc, substr(s.body_text, 1, 320), s.sort_order,
                   n.content, n.updated_at
            FROM user_notes n
            JOIN sections s ON s.id = n.section_id
            ORDER BY n.updated_at DESC;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [AnnotatedSection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let summary = readSummaryRow(stmt)
            let note = columnString(stmt, 10)
            let ts = sqlite3_column_double(stmt, 11)
            out.append(AnnotatedSection(
                summary: summary,
                note: note,
                updatedAt: Date(timeIntervalSince1970: ts)
            ))
        }
        return out
    }

    // MARK: - Browsing History

    public func recordHistoryVisit(sectionID: String, anchor: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970

        if let check = try? prepareUnlocked("""
            SELECT id, section_id, COALESCE(anchor, '') FROM history_entries ORDER BY visited_at DESC LIMIT 1;
        """) {
            defer { sqlite3_finalize(check) }
            if sqlite3_step(check) == SQLITE_ROW {
                let lastID = sqlite3_column_int64(check, 0)
                let lastSec = columnString(check, 1)
                let lastAnchor = columnString(check, 2)
                if lastSec == sectionID && lastAnchor == (anchor ?? "") {
                    if let upd = try? prepareUnlocked("UPDATE history_entries SET visited_at = ? WHERE id = ?;") {
                        defer { sqlite3_finalize(upd) }
                        sqlite3_bind_double(upd, 1, now)
                        sqlite3_bind_int64(upd, 2, lastID)
                        _ = sqlite3_step(upd)
                    }
                    return
                }
            }
        }

        if let ins = try? prepareUnlocked("""
            INSERT INTO history_entries (section_id, anchor, visited_at) VALUES (?, ?, ?);
        """) {
            defer { sqlite3_finalize(ins) }
            bindText(ins, 1, sectionID)
            bindOptionalText(ins, 2, anchor)
            sqlite3_bind_double(ins, 3, now)
            _ = sqlite3_step(ins)
        }
    }

    public func recentHistory(limit: Int = 200) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? prepareUnlocked("""
            SELECT h.id,
                   s.id, s.source_id, s.corpus, s.number, s.display_title, s.heading, s.breadcrumb, s.parent_irc, substr(s.body_text, 1, 240), s.sort_order,
                   h.anchor, h.visited_at
            FROM history_entries h
            JOIN sections s ON s.id = h.section_id
            ORDER BY h.visited_at DESC
            LIMIT ?;
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(limit))

        var out: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let entryID = sqlite3_column_int64(stmt, 0)
            let summary = SectionSummary(
                id: columnString(stmt, 1),
                sourceID: columnString(stmt, 2),
                corpus: CitationTarget.CorpusKind(rawValue: columnString(stmt, 3)) ?? .irc,
                number: columnString(stmt, 4),
                displayTitle: columnString(stmt, 5),
                heading: columnString(stmt, 6),
                breadcrumb: columnString(stmt, 7),
                parentIRC: columnOptionalString(stmt, 8),
                previewText: columnString(stmt, 9),
                sortOrder: Int(sqlite3_column_int64(stmt, 10))
            )
            let anchor = columnOptionalString(stmt, 11)
            let ts = sqlite3_column_double(stmt, 12)
            out.append(HistoryEntry(
                id: entryID,
                summary: summary,
                anchor: (anchor?.isEmpty == true) ? nil : anchor,
                visitedAt: Date(timeIntervalSince1970: ts)
            ))
        }
        return out
    }

    public func clearHistory() throws {
        try execute("DELETE FROM history_entries;")
    }
}
