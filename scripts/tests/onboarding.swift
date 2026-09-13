import Foundation

@main
struct OnboardingRegression {
    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ reason: String) {
            checks += 1
            guard value() else { fatalError("FAIL: \(reason)") }
        }
        expect(OnboardingState.needsSetup(persisted: [:], engineExists: false), "new users get setup")
        expect(!OnboardingState.needsSetup(persisted: ["dali.frontName": "Living room"], engineExists: false), "saved speaker choices bypass setup")
        expect(!OnboardingState.needsSetup(persisted: ["dali.delayTrimMs": 75], engineExists: false), "other existing personal preferences bypass setup")
        expect(!OnboardingState.needsSetup(persisted: [:], engineExists: true), "legacy engine folder bypasses setup")
        expect(OnboardingState.needsSetup(persisted: [OnboardingState.startedKey: true, "dali.frontName": "Kitchen"], engineExists: true), "interrupted discovery is still incomplete")
        expect(!OnboardingState.needsSetup(persisted: [OnboardingState.completedKey: true, OnboardingState.startedKey: true], engineExists: true), "completed setup stays complete on update")
        let suite = "DALI.OnboardingTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(75, forKey: "dali.delayTrimMs")
        let first = OnboardingState(defaults: defaults, persisted: [:], engineExists: false)
        first.goBack()
        expect(first.step == .welcome, "back does not underflow")
        first.advance(); first.advance()
        let resumed = OnboardingState(defaults: defaults,
                                      persisted: defaults.persistentDomain(forName: suite)!, engineExists: true)
        expect(resumed.isPresented && resumed.step == .speakers, "relaunch resumes selected step")
        resumed.advance(); resumed.advance(); resumed.advance()
        expect(resumed.step == .ready, "advance does not overflow")
        resumed.complete()
        expect(!resumed.isPresented && defaults.bool(forKey: OnboardingState.completedKey), "only completion sets permanent completion marker")
        expect(defaults.integer(forKey: "dali.delayTrimMs") == 75, "setup preserves unrelated user preferences")
        defaults.set(900, forKey: OnboardingState.stepKey)
        let invalid = OnboardingState(defaults: defaults, persisted: [:], engineExists: false)
        expect(invalid.step == .welcome, "invalid saved step safely resets")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DALI-extension-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("user/ChromeExtension")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: source.appendingPathComponent(path))
        }
        try write("manifest.json", #"{"manifest_version":3,"version":"1.0.0"}"#)
        try write("background.js", "importScripts('beacon.js')")
        try write("content.js", "// content 1")
        try write("beacon.js", "// beacon")
        try write("secret.txt", "do not package development files")
        try ExtensionInstaller.install(from: source, to: destination)
        expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("beacon.js").path), "beacon dependency is installed")
        expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("secret.txt").path), "nonruntime files are excluded")
        let existingDate = try destination.resourceValues(forKeys: [.creationDateKey]).creationDate
        try ExtensionInstaller.install(from: source, to: destination)
        let unchangedDate = try destination.resourceValues(forKeys: [.creationDateKey]).creationDate
        expect(unchangedDate == existingDate, "unchanged extension is not rewritten")
        try write("content.js", "// content 2")
        try ExtensionInstaller.install(from: source, to: destination)
        let updated = try String(contentsOf: destination.appendingPathComponent("content.js"), encoding: .utf8)
        expect(updated == "// content 2", "updated files replace the stable folder")
        try write("manifest.json", "invalid")
        do {
            try ExtensionInstaller.install(from: source, to: destination)
            fatalError("invalid bundle accepted")
        } catch ExtensionInstaller.InstallError.invalidManifest {}
        let preserved = try String(contentsOf: destination.appendingPathComponent("content.js"), encoding: .utf8)
        expect(preserved == "// content 2", "bad update leaves the installed copy intact")
        print("PASS: \(checks) onboarding and extension-install regression checks")
    }
}
