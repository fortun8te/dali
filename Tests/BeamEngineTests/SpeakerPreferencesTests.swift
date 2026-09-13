import XCTest
@testable import BeamEngine

final class SpeakerPreferencesTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let suite = "DALI.tests.speakers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        test(defaults)
    }

    func testFreshInstallDoesNotSelectAnotherPersonsSpeakers() {
        withDefaults { defaults in
            let preferences = SpeakerPreferences(defaults: defaults)
            XCTAssertEqual(preferences.frontName, "")
            XCTAssertEqual(preferences.backName, "")
            XCTAssertTrue(preferences.rememberedNames.isEmpty)
            XCTAssertFalse(preferences.enabled(name: "Living room", primary: false))
        }
    }

    func testExistingRoomKeepsPlacementSelectionAndCalibration() {
        withDefaults { defaults in
            let saved: [String: Any] = [
                "dali.frontName": "Desk", "dali.backName": "Sofa",
                "dali.on.Sofa": false, "dali.on.Kitchen": true,
                "dali.vol.Desk": 37.0, "dali.gain.Desk": 1.7,
                "dali.volumeLimit": 20.0
            ]
            for (key, value) in saved { defaults.set(value, forKey: key) }
            let preferences = SpeakerPreferences(defaults: defaults)
            XCTAssertEqual(preferences.frontName, "Desk")
            XCTAssertEqual(preferences.backName, "Sofa")
            XCTAssertTrue(preferences.enabled(name: "Desk", primary: true))
            XCTAssertFalse(preferences.enabled(name: "Sofa", primary: true))
            XCTAssertTrue(preferences.enabled(name: "Kitchen", primary: false))
            XCTAssertEqual(preferences.volume(name: "Desk"), 37)
            XCTAssertEqual(preferences.gain(name: "Desk"), 1.7)
            XCTAssertEqual(preferences.volumeLimit, 20)
            XCTAssertEqual(preferences.rememberedNames, ["Desk", "Sofa", "Kitchen"])
            for (key, value) in saved {
                XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject,
                               "Reading an upgrade must not rewrite a saved preference")
            }
        }
    }

    func testUnavailableSelectedSpeakersRemainRememberedAfterRelaunch() {
        withDefaults { defaults in
            for name in ["Desk", "Sofa", "Kitchen", "Bedroom"] {
                defaults.set(true, forKey: "dali.on.\(name)")
            }
            defaults.set(false, forKey: "dali.on.Patio")
            XCTAssertEqual(SpeakerPreferences(defaults: defaults).rememberedNames,
                           ["Desk", "Sofa", "Kitchen", "Bedroom"])
        }
    }

    func testDamagedVolumePreferencesCannotExceedBounds() {
        withDefaults { defaults in
            defaults.set(-5.0, forKey: "dali.vol.Desk")
            defaults.set(200.0, forKey: "dali.gain.Desk")
            defaults.set(500.0, forKey: "dali.volumeLimit")
            let preferences = SpeakerPreferences(defaults: defaults)
            XCTAssertEqual(preferences.volume(name: "Desk"), 0)
            XCTAssertEqual(preferences.gain(name: "Desk"), 4)
            XCTAssertEqual(preferences.volumeLimit, 100)
        }
    }

    func testMutingThirdAndFourthSpeakersKeepsCurrentGroup() {
        var membership = SpeakerSessionMembership()
        for name in ["Desk", "Sofa", "Kitchen", "Bedroom"] { membership.retain(name) }
        for name in ["Kitchen", "Bedroom"] {
            XCTAssertTrue(membership.contains(name: name, enabled: false, primary: false),
                          "Muting an extra must not reset the other speakers' clock")
        }
        XCTAssertFalse(membership.contains(name: "Patio", enabled: false, primary: false))
        membership.reset()
        XCTAssertFalse(membership.contains(name: "Kitchen", enabled: false, primary: false),
                       "A new session must release previously muted extra speakers")
        XCTAssertTrue(membership.contains(name: "Desk", enabled: false, primary: true),
                      "The established front/back mute behavior is preserved")
    }
}
