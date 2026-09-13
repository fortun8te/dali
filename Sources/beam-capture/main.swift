// beam-capture — headless harness: system audio -> FIFO for OwnTone.
// Usage: beam-capture --fifo /path/to/beam.pipe [--seconds 30]

import Foundation
import BeamCapture
import AVFoundation

// All state lives in this class, NOT in top-level code: top-level vars are
// MainActor-isolated in Swift 6 and audio/timer callbacks run on other queues.
final class Runner: @unchecked Sendable {
    let tap = ProcessTap()
    let fifo: FIFOWriter
    var converter: FormatConverter?
    var buffers = 0
    var bytes = 0
    let lock = NSLock()
    var timer: DispatchSourceTimer?

    init(fifoPath: String) {
        fifo = FIFOWriter(path: fifoPath)
    }

    func start() throws {
        tap.onBuffer = { [self] buffer in
            if converter == nil { converter = FormatConverter(from: buffer.format) }
            guard let data = converter?.convert(buffer) else { return }
            fifo.write(data)
            lock.lock()
            buffers += 1
            bytes += data.count
            lock.unlock()
        }
        try tap.start()
        if let fmt = tap.tapFormat {
            print("tap format: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch")
        }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "beam.stats"))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [self] in
            lock.lock()
            let b = buffers, by = bytes
            lock.unlock()
            print(String(format: "captured %d buffers, %.2f MB converted, fifo written %.2f MB, dropped %.2f MB",
                         b, Double(by) / 1e6,
                         Double(fifo.writtenBytes) / 1e6, Double(fifo.droppedBytes) / 1e6))
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        tap.stop()
        fifo.closePipe()
    }
}

var fifoPath = NSString(string: "~/.local/beam/media/beam.pipe").expandingTildeInPath
var seconds: Double? = nil
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let arg = args.popFirst() {
    switch arg {
    case "--fifo": if let v = args.popFirst() { fifoPath = NSString(string: v).expandingTildeInPath }
    case "--seconds": if let v = args.popFirst() { seconds = Double(v) }
    default:
        FileHandle.standardError.write("unknown arg \(arg)\n".data(using: .utf8)!)
        exit(2)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let runner = Runner(fifoPath: fifoPath)
do {
    try runner.start()
} catch {
    FileHandle.standardError.write("FATAL: \(error)\n".data(using: .utf8)!)
    exit(1)
}
print("beam-capture: tapping system audio -> \(fifoPath)")

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\nstopping")
    runner.stop()
    exit(0)
}
sigint.resume()

if let s = seconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) {
        runner.stop()
        exit(0)
    }
}

RunLoop.main.run()
