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
                                       directory + "/Contents/Helpers/owntone/lib/owntone-sqlext.so"])
            XCTAssertTrue(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
                arguments: arguments, configPath: config.confFile.path))
        }
    }

    func testReapingRejectsAnotherSQLiteExtensionOrExtraArguments() {
        let config = OwnToneConfig(rootDir: URL(fileURLWithPath: "/tmp/isolated DALI/engine"))
        let binary = URL(fileURLWithPath: "/tmp/Moved DALI.app/Contents/Helpers/owntone/owntone")
        let arguments = ["-f", "-c", config.confFile.path, "-s",
                         "/tmp/Moved DALI.app/Contents/Helpers/owntone/lib/owntone-sqlext.so"]
        XCTAssertTrue(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: arguments, configPath: config.confFile.path))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: Array(arguments.dropLast()) + ["/tmp/other-sqlext.so"],
            configPath: config.confFile.path))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(executablePath: binary.path,
            arguments: arguments + ["--other"], configPath: config.confFile.path))
    }
}
