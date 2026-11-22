// DALI — the shared app session: owns the onboarding state and the one DALIStore.
// Lives beside the @main entry so the app controller test can compile it too.

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class DALIApplicationSession {
    static let shared = DALIApplicationSession()

    let onboarding: OnboardingState
    private(set) var store: DALIStore?

    private init() {
        let defaults = UserDefaults.standard
        let persisted = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.fortun8te.dali") ?? [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let engine = support.appendingPathComponent("DALI/engine")
        onboarding = OnboardingState(defaults: defaults, persisted: persisted,
                                     engineExists: FileManager.default.fileExists(atPath: engine.path))
        // Only a previously requested managed extension copy is updated.
        // Existing unpacked installs in other folders are left where they are.
        // Off the main thread: it compares and copies files, and launch is
        // when the window is trying to appear.
        Task.detached(priority: .utility) {
            do { try ExtensionInstaller.updateExistingInstall() }
            catch { NSLog("DALI browser extension update: %@", error.localizedDescription) }
        }
        if !onboarding.isPresented { ensureStore() }
    }

    func ensureStore() {
        guard store == nil else { return }
        store = DALIStore()
    }

    func completeSetup() {
        onboarding.complete()
        ensureStore()
    }
}
