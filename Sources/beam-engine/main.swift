// beam-engine — CLI for the OwnTone supervisor, used by the e2e script and
// for headless debugging. Runs the engine in the foreground until Ctrl-C.
// Usage: beam-engine [--vendor <dir>] [--root <dir>] [--select name1,name2] [--play]

import Foundation
import BeamEngine

final class CLI: @unchecked Sendable {
    var vendorBin = NSString(string: "~/Downloads/beam/vendor/owntone/owntone").expandingTildeInPath
    // MUST match the GUI app's root (DALIStore uses Application Support/DALI/engine).
    // These are not two independent sandboxes: an engine is a machine-global thing
    // — it binds UDP 319/320 for PTP and TCP 3689 for the API. Pointing the CLI at
    // its own root did not give it its own engine, it gave us two engines fighting
    // over the same global ports (and two live logs). Same root = same instance.
    var rootDir = NSString(string: "~/Library/Application Support/DALI/engine").expandingTildeInPath
    var selectNames: [String] = []
    var play = false
    var supervisor: EngineSupervisor?   // retained for the process lifetime

    func run() async {
        let config = OwnToneConfig(rootDir: URL(fileURLWithPath: rootDir))
        let supervisor = EngineSupervisor(binary: URL(fileURLWithPath: vendorBin), config: config)
        self.supervisor = supervisor
        await supervisor.setStateHandler { state in print("engine: \(state)") }

        do {
            try await supervisor.start()
            let api = BeamAPI()
            let outputs = try await api.outputs()
            print("outputs (\(outputs.count)):")
            for o in outputs { print("  \(o.selected ? "*" : " ") \(o.name) [\(o.type)] vol \(o.volume)") }

            if !selectNames.isEmpty {
                let ids = outputs.filter { selectNames.contains($0.name) }.map(\.id)
                guard ids.count == selectNames.count else {
                    print("ERROR: not all of \(selectNames) found"); exit(1)
                }
                try await api.setOutputs(ids: ids)
                print("selected: \(selectNames.joined(separator: ", "))")
            }
            if play {
                try? await api.rescan()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard let uri = try await api.pipeTrackURI(named: "beam.pipe") else {
                    print("ERROR: pipe track not in library"); exit(1)
                }
                try await api.playPipe(uri: uri)
                await supervisor.setResumePlayback(true)
                print("playing pipe \(uri)")
            }
        } catch {
            print("FATAL: \(error)")
            exit(1)
        }
    }
}

let cli = CLI()
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let arg = args.popFirst() {
    switch arg {
    case "--vendor": if let v = args.popFirst() { cli.vendorBin = NSString(string: v).expandingTildeInPath }
    case "--root": if let v = args.popFirst() { cli.rootDir = NSString(string: v).expandingTildeInPath }
    case "--select": if let v = args.popFirst() { cli.selectNames = v.components(separatedBy: ",") }
    case "--play": cli.play = true
    default: FileHandle.standardError.write("unknown arg \(arg)\n".data(using: .utf8)!); exit(2)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
Task { await cli.run() }
RunLoop.main.run()
