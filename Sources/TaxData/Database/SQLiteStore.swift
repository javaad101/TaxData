import Foundation
import SQLite3

internal let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum TaxDatabaseError: Error, LocalizedError, Sendable {
    case sqliteFailure(String)
    case encodingFailure

    public var errorDescription: String? {
        switch self {
        case .sqliteFailure(let msg): return "Database error: \(msg)"
        case .encodingFailure: return "Failed to serialize document node."
        }
    }
}

/// Thread-safe SQLite3 + FTS5 local store powering sub-millisecond citation jumps,
/// BM25 full-text search, Spotlight indexing, Siri/Apple Intelligence queries, and user study data.
public final class TaxDatabase: @unchecked Sendable {
    public static let shared: TaxDatabase = {
        do {
            return try TaxDatabase(url: defaultDatabaseURL())
        } catch {
            return try! TaxDatabase(inMemory: true)
        }
    }()

    public static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TaxCodeReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("taxlaw.sqlite")
    }

    public static func volumesDirectoryURL() -> URL {
        let dir = defaultDatabaseURL().deletingLastPathComponent().appendingPathComponent("Volumes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public let databaseURL: URL?
    internal let lock = NSLock()
    internal nonisolated(unsafe) var db: OpaquePointer?

    public init(url: URL) throws {
        self.databaseURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) } ?? "open failed"
            sqlite3_close(handle)
            throw TaxDatabaseError.sqliteFailure(msg)
        }
        self.db = handle
        try configureAndMigrate()
    }

    public init(inMemory: Bool) throws {
        self.databaseURL = nil
        var handle: OpaquePointer?
        if sqlite3_open(":memory:", &handle) != SQLITE_OK {
            throw TaxDatabaseError.sqliteFailure("Failed to open in-memory database")
        }
        self.db = handle
        try configureAndMigrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func configureAndMigrate() throws {
        try execute("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS sources (
            source_id TEXT PRIMARY KEY,
            corpus TEXT NOT NULL,
            title TEXT NOT NULL,
            file_path TEXT,
            imported_at REAL NOT NULL,
            section_count INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS sections (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            corpus TEXT NOT NULL,
            number TEXT NOT NULL,
            display_title TEXT NOT NULL,
            heading TEXT NOT NULL,
            breadcrumb TEXT NOT NULL,
            parent_irc TEXT,
            body_text TEXT NOT NULL,
            node_json BLOB NOT NULL,
            sort_order INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_sections_corpus_number ON sections(corpus, number COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_sections_parent_irc ON sections(parent_irc COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_sections_source ON sections(source_id);
        CREATE INDEX IF NOT EXISTS idx_sections_order ON sections(corpus, sort_order);

        CREATE VIRTUAL TABLE IF NOT EXISTS sections_fts USING fts5(
            id UNINDEXED,
            corpus UNINDEXED,
            display_title,
            heading,
            breadcrumb,
            body_text,
            tokenize='porter unicode61'
        );

        CREATE TABLE IF NOT EXISTS bookmark_folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            icon TEXT NOT NULL,
            sort_order INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS bookmarks (
            section_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            anchor TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            PRIMARY KEY (section_id, folder_id, anchor)
        );

        CREATE TABLE IF NOT EXISTS user_notes (
            section_id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS history_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            section_id TEXT NOT NULL,
            anchor TEXT,
            visited_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_history_visited_at ON history_entries(visited_at DESC);
        """)
        try seedDefaultCourseFoldersIfNeeded()
    }

    // MARK: - Row & Low-Level SQLite Primitives

    internal func readSummaryRow(_ stmt: OpaquePointer?) -> SectionSummary {
        SectionSummary(
            id: columnString(stmt, 0),
            sourceID: columnString(stmt, 1),
            corpus: CitationTarget.CorpusKind(rawValue: columnString(stmt, 2)) ?? .irc,
            number: columnString(stmt, 3),
            displayTitle: columnString(stmt, 4),
            heading: columnString(stmt, 5),
            breadcrumb: columnString(stmt, 6),
            parentIRC: columnOptionalString(stmt, 7),
            previewText: columnString(stmt, 8),
            sortOrder: Int(sqlite3_column_int64(stmt, 9))
        )
    }

    internal func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(sql)
    }

    internal func executeUnlocked(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? currentErrorMessageUnlocked()
            sqlite3_free(errMsg)
            throw TaxDatabaseError.sqliteFailure(message)
        }
    }

    internal func prepareUnlocked(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw TaxDatabaseError.sqliteFailure(currentErrorMessageUnlocked())
        }
        return stmt
    }

    internal func stepDoneUnlocked(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw TaxDatabaseError.sqliteFailure(currentErrorMessageUnlocked())
        }
    }

    internal func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { cStr in
            sqlite3_bind_text(stmt, index, cStr, -1, sqliteTransient)
        }
    }

    internal func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    internal func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { rawBuf in
            sqlite3_bind_blob(stmt, index, rawBuf.baseAddress, Int32(data.count), sqliteTransient)
        }
    }

    internal func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    internal func columnOptionalString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cStr)
    }

    internal func currentErrorMessageUnlocked() -> String {
        db.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) } ?? "Unknown SQLite error"
    }
}
