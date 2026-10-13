import Foundation
import SQLite3
import XCTest
@testable import BeamEngine

/// OwnTone's library indexes titles with a custom `DAAP` collation that its own
/// SQLite extension registers. These tests build a library the same way and
/// check that the startup integrity probe can actually see inside it.
final class DatabaseProbeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dali-db-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A library file with a `DAAP`-collated index spanning many pages. The
    /// collation here is case-insensitive, like the real one, and is registered
    /// only while the file is written: a reader gets no such collation unless it
    /// brings its own, exactly like the app's probe.
    private func makeLibrary(rows: Int = 3000) throws -> URL {
        let url = root.appendingPathComponent("songs3.db")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw BeamAPIError(what: "open failed") }
        defer { sqlite3_close(db) }
        sqlite3_create_collation(db, "DAAP", SQLITE_UTF8, nil) { _, la, a, lb, b in
            let x = String(decoding: UnsafeRawBufferPointer(start: a, count: Int(la)), as: UTF8.self).lowercased()
            let y = String(decoding: UnsafeRawBufferPointer(start: b, count: Int(lb)), as: UTF8.self).lowercased()
            return x == y ? 0 : (x < y ? -1 : 1)
        }
        let statements = [
            "PRAGMA journal_mode=DELETE",
            "CREATE TABLE files (id INTEGER PRIMARY KEY, title VARCHAR(1024) COLLATE DAAP)",
            "CREATE INDEX idx_title ON files(title COLLATE DAAP)",
        ]
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw BeamAPIError(what: "setup failed: \(sql)")
            }
        }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for i in 0..<rows {
            // Mixed case, so the case-insensitive writer and a plain reader
            // disagree about key order.
            let word = i % 2 == 0 ? "track" : "Track"
            sqlite3_exec(db, "INSERT INTO files(title) VALUES ('\(word) number \(i) — \(String(repeating: "x", count: 40))')", nil, nil, nil)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return url
    }

    /// Smash a middle page of the file, the way a torn write or full disk would.
    private func damage(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let pageSize: UInt64 = 4096
        XCTAssertGreaterThan(size, pageSize * 6, "fixture must span several pages")
        try handle.seek(toOffset: pageSize * 3)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: Int(pageSize)))
    }

    func testHealthyLibraryWithCustomCollationIsHealthy() throws {
        XCTAssertTrue(EngineSupervisor.databaseIsHealthy(at: try makeLibrary()))
    }

    func testDamagedLibraryWithCustomCollationIsDetected() throws {
        // The old probe could not prepare `PRAGMA quick_check` on a DAAP library
        // ("no such collation sequence"), treated that as "fine", and so never
        // saw any real corruption.
        let url = try makeLibrary()
        try damage(url)
        XCTAssertFalse(EngineSupervisor.databaseIsHealthy(at: url))
    }

    func testProbeDoesNotFlagCollationOrderingAsCorruption() throws {
        // The stand-in collation orders keys differently from OwnTone's real one.
        // quick_check checks page structure, not key order, so a healthy library
        // must still pass; the probe must never quarantine a user's library on a
        // guess.
        let url = try makeLibrary(rows: 400)
        XCTAssertTrue(EngineSupervisor.databaseIsHealthy(at: url))
    }

    func testMissingEmptyAndForeignFilesKeepTheirExistingVerdicts() throws {
        XCTAssertTrue(EngineSupervisor.databaseIsHealthy(at: root.appendingPathComponent("absent.db")))
        let empty = root.appendingPathComponent("empty.db")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertTrue(EngineSupervisor.databaseIsHealthy(at: empty))
        let foreign = root.appendingPathComponent("foreign.db")
        try Data(repeating: 0x41, count: 8192).write(to: foreign)
        XCTAssertFalse(EngineSupervisor.databaseIsHealthy(at: foreign))
    }

    func testRepeatedStartupDeathsOnlyDiscardALibraryThatFailsItsProbe() {
        // Three quick deaths with the web root missing (2026-10-03) quarantined a
        // library that was fine. Only a library the probe condemns may go.
        XCTAssertFalse(EngineSupervisor.shouldDiscardLibrary(afterQuickDeaths: 3, libraryIsHealthy: true))
        XCTAssertTrue(EngineSupervisor.shouldDiscardLibrary(afterQuickDeaths: 3, libraryIsHealthy: false))
        XCTAssertFalse(EngineSupervisor.shouldDiscardLibrary(afterQuickDeaths: 2, libraryIsHealthy: false))
    }
}
