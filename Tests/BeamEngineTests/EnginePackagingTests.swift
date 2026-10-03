import Foundation
import XCTest
@testable import BeamEngine

final class EnginePackagingTests: XCTestCase {
    func testSQLiteExtensionPathFollowsRelocatedEngineBinary() {
        let config = OwnToneConfig(rootDir: URL(fileURLWithPath: "/tmp/isolated DALI/engine"))
        for directory in ["/Applications/DALI.app", "/tmp/Moved DALI.app"] {
            let binary = URL(fileURLWithPath: directory + "/Contents/Helpers/owntone/owntone")
            let arguments = config.engineArguments(for: binary)
            XCTAssertEqual(arguments, ["-f", "-c", config.confFile.path, "-s",
                                       directory + "/Contents/Helpers/owntone/lib/owntone-sqlext.so", "-w",
                                       directory + "/Contents/Helpers/owntone/htdocs"])
            XCTAssertTrue(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
                arguments: arguments, configPath: config.confFile.path))
        }
    }

    func testCacheDirectoryStaysInPersistentEngineRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dali-resource-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = OwnToneConfig(rootDir: root)
        let cache = root.appendingPathComponent("var/cache")
        XCTAssertTrue(config.rendered.contains("cache_dir = \"\(cache.path)\""))
        try config.materialize()
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path, isDirectory: &directory))
        XCTAssertTrue(directory.boolValue)
    }

    func testReapingRejectsAnotherSQLiteExtensionOrExtraArguments() {
        let config = OwnToneConfig(rootDir: URL(fileURLWithPath: "/tmp/isolated DALI/engine"))
        let binary = URL(fileURLWithPath: "/tmp/Moved DALI.app/Contents/Helpers/owntone/owntone")
        let arguments = ["-f", "-c", config.confFile.path, "-s",
                         "/tmp/Moved DALI.app/Contents/Helpers/owntone/lib/owntone-sqlext.so", "-w",
                         "/tmp/Moved DALI.app/Contents/Helpers/owntone/htdocs"]
        XCTAssertTrue(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: arguments, configPath: config.confFile.path))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: Array(arguments.prefix(4)) + ["/tmp/other-sqlext.so"] + Array(arguments.suffix(2)),
            configPath: config.confFile.path))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: Array(arguments.dropLast()) + ["/tmp/other-htdocs"],
            configPath: config.confFile.path))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: arguments + ["--other"], configPath: config.confFile.path))
    }
}
