import XCTest
@testable import BeamEngine

final class BeamEngineTests: XCTestCase {

    func testOutputsDecoding() throws {
        // Canned from a real Phase 0 curl response.
        let json = """
        {"outputs":[{"id":"158701231196944","name":"Front","type":"AirPlay 2",
        "selected":true,"has_password":false,"requires_auth":false,"needs_auth_key":false,
        "volume":25,"offset_ms":0,"format":"alac","supported_formats":["alac"]},
        {"id":"141059389182796","name":"Back","type":"AirPlay 2","selected":false,
        "has_password":false,"requires_auth":false,"needs_auth_key":false,"volume":50,
        "offset_ms":0,"format":"alac","supported_formats":["alac"]}]}
        """
        struct Wrapper: Codable { let outputs: [Output] }
        let outs = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).outputs
        XCTAssertEqual(outs.count, 2)
        XCTAssertEqual(outs[0].name, "Front")
        XCTAssertTrue(outs[0].selected)
        XCTAssertEqual(outs[1].volume, 50)
    }

    func testPlayerStateDecoding() throws {
        let json = """
        {"state":"play","repeat":"off","consume":false,"shuffle":false,"volume":25,
        "item_id":1,"item_length_ms":0,"item_progress_ms":2760}
        """
        let st = try JSONDecoder().decode(PlayerState.self, from: Data(json.utf8))
        XCTAssertEqual(st.state, "play")
        XCTAssertEqual(st.volume, 25)
    }

    func testConfigEscapesPathsAndRepairsNonFifoPipe() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beam \"quoted\" \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cfg = OwnToneConfig(rootDir: root)
        try FileManager.default.createDirectory(at: cfg.mediaDir, withIntermediateDirectories: true)
        // A regular file squatting on the pipe path must be replaced by a FIFO.
        XCTAssertTrue(FileManager.default.createFile(atPath: cfg.pipePath.path, contents: Data("x".utf8)))
        try cfg.materialize()
        var st = stat()
        XCTAssertEqual(lstat(cfg.pipePath.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFIFO)
        let conf = try String(contentsOf: cfg.confFile, encoding: .utf8)
        XCTAssertFalse(conf.contains("beam \"quoted\""), "an unescaped quote would end the string early")
        XCTAssertTrue(conf.contains("beam \\\"quoted\\\""))
    }

    func testMalformedOutputStillDecodesAsAliveEngine() throws {
        // One odd element must not fail the list (a failed poll is a health strike).
        let json = #"{"outputs":[{"id":"1","name":"A","type":"AirPlay 2","selected":true,"volume":null},{"name":"no id"}]}"#
        let outs = try JSONDecoder().decode(OutputsProbe.self, from: Data(json.utf8)).outputs.compactMap(\.output)
        XCTAssertEqual(outs.map(\.id), ["1"])
        XCTAssertEqual(outs.first?.volume, 0)
        let ps = try JSONDecoder().decode(PlayerState.self, from: Data(#"{"state":"play"}"#.utf8))
        XCTAssertEqual(ps.state, "play")
        XCTAssertEqual(ps.volume, 0)
    }

    private struct OutputsProbe: Decodable {
        struct Item: Decodable {
            let output: Output?
            init(from decoder: Decoder) throws { output = try? Output(from: decoder) }
        }
        let outputs: [Item]
    }

    func testConfigMaterializesDirsPipeAndFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beam-engine-test-\(UUID().uuidString)")
        let cfg = OwnToneConfig(rootDir: root)
        try cfg.materialize()

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfg.mediaDir.path, isDirectory: &isDir) && isDir.boolValue)
        let attrs = try FileManager.default.attributesOfItem(atPath: cfg.pipePath.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeUnknown)   // FIFO reports as unknown
        let conf = try String(contentsOf: cfg.confFile, encoding: .utf8)
        XCTAssertTrue(conf.contains("pipe_autostart = true"))
        XCTAssertTrue(conf.contains("filescan_disable = false"))
        XCTAssertTrue(conf.contains("vacuum = false"))
        XCTAssertTrue(conf.contains("trusted_networks = { \"localhost\" }"))
        XCTAssertTrue(conf.contains("websocket_interface = \"lo0\""))
        XCTAssertTrue(conf.contains(cfg.mediaDir.path))
        XCTAssertTrue(conf.contains("uid = \"\(NSUserName())\""))

        // Once the persistent library exists, later launches should not block
        // audio startup by scanning the user's Music folder again.
        XCTAssertTrue(FileManager.default.createFile(atPath: cfg.dbFile.path, contents: Data()))
        try cfg.materialize()
        let resumedConf = try String(contentsOf: cfg.confFile, encoding: .utf8)
        XCTAssertTrue(resumedConf.contains("filescan_disable = true"))
        try? FileManager.default.removeItem(at: root)
    }
}
