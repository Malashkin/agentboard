import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

typealias Row = [String: Any]

/// Minimal SQLite wrapper. Not thread-safe by itself: Core uses it from one serial queue.
final class Database {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw NSError(domain: "AgentBoard.DB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open database \(path)"])
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=3000;")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            NSLog("AgentBoard SQL error: \(err.map { String(cString: $0) } ?? "?") in \(sql)")
            sqlite3_free(err)
        }
        return rc == SQLITE_OK
    }

    @discardableResult
    func query(_ sql: String, _ args: [Any] = []) -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("AgentBoard SQL prepare error: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (n, a) in args.enumerated() {
            let idx = Int32(n + 1)
            switch a {
            case is NSNull: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(a)", -1, SQLITE_TRANSIENT)
            }
        }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: Row = [:]
                for c in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                    case SQLITE_TEXT:
                        if let t = sqlite3_column_text(stmt, c) { row[name] = String(cString: t) }
                    default: break
                    }
                }
                rows.append(row)
            } else {
                if rc != SQLITE_DONE {
                    NSLog("AgentBoard SQL step error: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
                }
                break
            }
        }
        return rows
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(db) }

    func update(_ table: String, id: Any, idColumn: String = "id", _ fields: [String: Any]) {
        guard !fields.isEmpty else { return }
        let keys = fields.keys.sorted()
        let sql = "UPDATE \(table) SET " + keys.map { "\($0)=?" }.joined(separator: ", ") + " WHERE \(idColumn)=?"
        query(sql, keys.map { fields[$0]! } + [id])
    }
}
