import Foundation
import Observation

/// Setup is a first-install decision, never a release-version requirement.
/// The explicit started marker wins over the engine folder created during setup,
/// so quitting halfway through discovery does not accidentally complete setup.
@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, audio, speakers, browser, ready

        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .audio: "System audio"
            case .speakers: "Your speakers"
            case .browser: "Video sync"
            case .ready: "Ready"
            }
        }
    }

    static let completedKey = "dali.onboarding.completed"
    static let startedKey = "dali.onboarding.started"
    static let stepKey = "dali.onboarding.step"

    private let defaults: UserDefaults?
    private(set) var isPresented: Bool
    private(set) var step: Step

    static func needsSetup(persisted: [String: Any], engineExists: Bool) -> Bool {
        if (persisted[completedKey] as? Bool) == true { return false }
        if (persisted[startedKey] as? Bool) == true { return true }
        let established = persisted.keys.contains {
            $0.hasPrefix("dali.") && !$0.hasPrefix("dali.onboarding.")
        }
        return !established && !engineExists
    }

    init(defaults: UserDefaults, persisted: [String: Any], engineExists: Bool) {
        self.defaults = defaults
        isPresented = Self.needsSetup(persisted: persisted, engineExists: engineExists)
        step = Step(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .welcome
        if isPresented { defaults.set(true, forKey: Self.startedKey) }
    }

    /// A separate snapshot executable uses this initializer. No UserDefaults,
    /// DALIStore, audio tap, network listener, or engine is created in that process.
    init(preview step: Step) {
        defaults = nil
        isPresented = true
        self.step = step
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        setStep(next)
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        setStep(previous)
    }

    private func setStep(_ next: Step) {
        step = next
        defaults?.set(next.rawValue, forKey: Self.stepKey)
    }

    func complete() {
        defaults?.set(true, forKey: Self.completedKey)
        defaults?.removeObject(forKey: Self.stepKey)
        isPresented = false
    }
}
