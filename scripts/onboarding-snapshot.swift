import AppKit
import SwiftUI

/// Standalone UI renderer. This executable does not link DALIStore, DALIApp,
/// ProcessTap, the beacon, or the engine. It never reads/writes DALI preferences.
@main
struct OnboardingSnapshot {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: onboarding-snapshot OUTPUT_DIRECTORY APP_ICON_PATH")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        let icon = NSImage(contentsOfFile: CommandLine.arguments[2])
        let speakers = [
            OnboardingSpeaker(id: "1", name: "Living room", detail: "AirPlay 2", selected: true),
            OnboardingSpeaker(id: "2", name: "Kitchen", detail: "AirPlay 2", selected: true),
            OnboardingSpeaker(id: "3", name: "Bedroom", detail: "AirPlay 2", selected: false),
        ]
        for step in OnboardingState.Step.allCases {
            let state = OnboardingState(preview: step)
            let root = OnboardingView(state: state, speakers: speakers, preview: true, previewIcon: icon)
            let view = NSHostingView(rootView: root)
            let bounds = NSRect(x: 0, y: 0, width: 420, height: step == .welcome || step == .ready ? 390 : 540)
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            view.frame = bounds
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                fatalError("could not create bitmap")
            }
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("could not encode PNG")
            }
            let file = output.appendingPathComponent("onboarding-\(step.rawValue + 1)-\(step.label.lowercased().replacingOccurrences(of: " ", with: "-")).png")
            try png.write(to: file)
            print(file.path)
            window.close()
        }
    }
}
