import Foundation
import SQLite3

/// Persists the app's Agent settings and changed leases in one local transaction.
/// A row holds one lease and its events so a request never re-encodes prior history.
final class AgentAuditStore {
    private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let copyValue = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(files: AgentFiles) throws {
        try files.prepareDirectory()
        var info = stat()
        if lstat(files.database.path, &info) == 0,
           info.st_uid != getuid() || info.st_mode & S_IFMT != S_IFREG {
            throw AgentToolError.storage
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(files.database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            throw AgentToolError.storage
        }
        database = handle
        guard chmod(files.database.path, 0o600) == 0 else { throw AgentToolError.storage }
        try execute("CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS leases (id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)")
    }

    deinit { sqlite3_close(database) }

    /// The settings row is the migration marker. Legacy JSON remains available as the original backup.
    func load(legacy url: URL) throws -> AgentLedger {
        if var saved = try read(AgentLedger.self, sql: "SELECT payload FROM settings WHERE id = 1").first {
            saved.leases = try read(AgentLease.self, sql: "SELECT payload FROM leases ORDER BY rowid")
            return saved
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return AgentLedger() }
        let legacy = try decoder.decode(AgentLedger.self, from: Data(contentsOf: url))
        var settings = legacy
        settings.leases = []
        try write(settings: settings, leases: legacy.leases)
        return legacy
    }

    /// Persist metadata changes and lease endings together before changing SSH ownership.
    func write(settings: AgentLedger?, leases: [AgentLease]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            if let settings {
                try statement("INSERT OR REPLACE INTO settings VALUES (1, ?)") { query in
                    try bind(encoder.encode(settings), at: 1, to: query)
                    guard sqlite3_step(query) == SQLITE_DONE else { throw AgentToolError.storage }
                }
            }
            if !leases.isEmpty {
                try statement("""
                    INSERT INTO leases (id, payload) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                    """) { query in
                    for lease in leases {
                        guard sqlite3_bind_text(query, 1, lease.id.uuidString, -1, copyValue) == SQLITE_OK else {
                            throw AgentToolError.storage
                        }
                        try bind(encoder.encode(lease), at: 2, to: query)
                        guard sqlite3_step(query) == SQLITE_DONE, sqlite3_reset(query) == SQLITE_OK else {
                            throw AgentToolError.storage
                        }
                    }
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, sql: String) throws -> [Value] {
        try statement(sql) { query in
            var values: [Value] = []
            var status = sqlite3_step(query)
            while status == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(query, 0) else { throw AgentToolError.storage }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
                values.append(try decoder.decode(type, from: data))
                status = sqlite3_step(query)
            }
            guard status == SQLITE_DONE else { throw AgentToolError.storage }
            return values
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw AgentToolError.storage }
    }

    private func statement<Result>(_ sql: String, _ run: (OpaquePointer) throws -> Result) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AgentToolError.storage
        }
        defer { sqlite3_finalize(statement) }
        return try run(statement)
    }

    private func bind(_ data: Data, at index: Int32, to query: OpaquePointer) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(query, index, $0.baseAddress, Int32($0.count), copyValue) }
        guard result == SQLITE_OK else { throw AgentToolError.storage }
    }
}
