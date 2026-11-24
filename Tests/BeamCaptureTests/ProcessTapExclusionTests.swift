import XCTest
import CoreAudio
@testable import BeamCapture

private final class DescriptionHALFixture {
    let uuid = UUID()
    var processes: Set<AudioObjectID> = [10]
    var status: OSStatus = noErr
    var reads = 0
    var writes = 0
    var ignoreSetter = false
    var changeReadbackMute = false
    var delayedReadbacks = 0
    var stagedProcesses: Set<AudioObjectID>?
    var current = true
    var afterWrite: (() -> Void)?

    func read() -> CATapDescription? {
        reads += 1
        if let staged = stagedProcesses {
            if delayedReadbacks > 0 { delayedReadbacks -= 1 }
            else { processes = staged; stagedProcesses = nil }
        }
        let value = CATapDescription(stereoGlobalTapButExcludeProcesses: processes.sorted())
        value.uuid = uuid
        value.name = "existing tap"
        value.isPrivate = true
        value.muteBehavior = .mutedWhenTapped
        if reads > 1 && changeReadbackMute { value.muteBehavior = .unmuted }
        return value
    }

    func write(_ value: CATapDescription) -> OSStatus {
        writes += 1
        XCTAssertEqual(value.uuid, uuid)
        XCTAssertEqual(value.name, "existing tap")
        XCTAssertTrue(value.isPrivate)
        XCTAssertTrue(value.isExclusive)
        XCTAssertTrue(value.isMixdown)
        XCTAssertFalse(value.isMono)
        XCTAssertEqual(value.muteBehavior, .mutedWhenTapped)
        if status == noErr && !ignoreSetter {
            if delayedReadbacks > 0 { stagedProcesses = Set(value.processes) }
            else { processes = Set(value.processes) }
        }
        afterWrite?()
        return status
    }

    func update(_ requested: Set<AudioObjectID>,
                wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> ProcessTapExclusionRefresh.Result {
        ProcessTapExclusionRefresh.apply(previous: [10], requested: requested,
            isCurrent: { self.current }, read: read, write: write, wait: wait)
    }
}

final class ProcessTapExclusionTests: XCTestCase {
    func testAcceptedAsynchronousUpdateWaitsBrieflyForUnchangedReadback() {
        let hal = DescriptionHALFixture()
        hal.delayedReadbacks = 2
        var waited = 0.0
        XCTAssertEqual(hal.update([10, 20], wait: { waited += $0 }), .updated)
        XCTAssertEqual(hal.processes, [10, 20])
        XCTAssertEqual(waited, 0.02, accuracy: 1e-9)
        XCTAssertEqual(hal.writes, 1)
    }

    func testUnconfirmedSetterIsBoundedAndWrongIdentityDoesNotWait() {
        let pending = DescriptionHALFixture()
        pending.ignoreSetter = true
        var waited = 0.0
        XCTAssertEqual(pending.update([10, 20], wait: { waited += $0 }), .failed)
        XCTAssertEqual(waited, 0.05, accuracy: 1e-9)
        XCTAssertEqual(pending.writes, 1)
        XCTAssertEqual(pending.reads, 7)
        let wrong = DescriptionHALFixture()
        wrong.changeReadbackMute = true
        var wrongWaits = 0
        XCTAssertEqual(wrong.update([10, 20], wait: { _ in wrongWaits += 1 }), .failed)
        XCTAssertEqual(wrongWaits, 0)
    }

    func testStopDuringConfirmationWaitPreventsFurtherHALReads() {
        let hal = DescriptionHALFixture()
        hal.ignoreSetter = true
        var waits = 0
        XCTAssertEqual(hal.update([10, 20], wait: { _ in waits += 1; hal.current = false }), .stale)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(hal.reads, 2)
        XCTAssertEqual(hal.writes, 1)
    }

    func testNewCallProcessChangesExistingDescriptionWithoutInvalidation() {
        let hal = DescriptionHALFixture()
        XCTAssertEqual(hal.update([10, 20]), .updated)
        XCTAssertEqual(hal.processes, [10, 20])
        XCTAssertEqual(hal.reads, 2, "Setter success requires a readback")
        XCTAssertEqual(hal.writes, 1)
    }

    func testFailedSetterAndIgnoredSetterRequestFallback() {
        let failed = DescriptionHALFixture()
        failed.status = -1
        XCTAssertEqual(failed.update([10, 20]), .failed)
        XCTAssertEqual(failed.processes, [10])
        let ignored = DescriptionHALFixture()
        ignored.ignoreSetter = true
        XCTAssertEqual(ignored.update([10, 20]), .failed)
        let changedIdentity = DescriptionHALFixture()
        changedIdentity.changeReadbackMute = true
        XCTAssertEqual(changedIdentity.update([10, 20]), .failed,
                       "HAL must preserve the live tap's original mute behavior")
    }

    func testReadFailureAndStopDuringReadDoNotWrite() {
        let unreadable = DescriptionHALFixture()
        XCTAssertEqual(ProcessTapExclusionRefresh.apply(previous: [10], requested: [10, 20],
            isCurrent: { true }, read: { nil }, write: unreadable.write), .failed)
        XCTAssertEqual(unreadable.writes, 0)
        let stopped = DescriptionHALFixture()
        XCTAssertEqual(ProcessTapExclusionRefresh.apply(previous: [10], requested: [10, 20],
            isCurrent: { stopped.current }, read: { let value = stopped.read(); stopped.current = false; return value },
            write: stopped.write), .stale)
        XCTAssertEqual(stopped.writes, 0)
    }

    func testNewProcessRefreshDropsRetiredIDsWithoutRecreatingIdentity() {
        let hal = DescriptionHALFixture()
        XCTAssertEqual(hal.update([20]), .updated)
        XCTAssertEqual(hal.processes, [20])
        XCTAssertEqual(hal.writes, 1)
    }

    func testUnchangedAndRemovalOnlyDoNotTouchHAL() {
        let hal = DescriptionHALFixture()
        XCTAssertEqual(hal.update([10]), .unchanged)
        XCTAssertEqual(hal.update([]), .unchanged)
        XCTAssertEqual(hal.reads, 0)
        XCTAssertEqual(hal.writes, 0)
    }

    func testStoppedOrReplacedGenerationCannotPublishUpdateOrFailure() {
        let stopped = DescriptionHALFixture()
        stopped.current = false
        XCTAssertEqual(stopped.update([10, 20]), .stale)
        XCTAssertEqual(stopped.writes, 0)
        let replaced = DescriptionHALFixture()
        replaced.afterWrite = { replaced.current = false }
        XCTAssertEqual(replaced.update([10, 20]), .stale)
    }
}
