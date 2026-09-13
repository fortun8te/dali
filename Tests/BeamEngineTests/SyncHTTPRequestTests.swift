import XCTest
@testable import BeamEngine

final class SyncHTTPRequestTests: XCTestCase {
    func testLegacyStatusAndExtensionControl() throws {
        XCTAssertEqual(try SyncHTTPRequest(header: "GET / HTTP/1.1\r\nHost: 127.0.0.1:3697\r\n\r\n").route, "/")
        let request = try SyncHTTPRequest(header: "GET /cut?t=1 HTTP/1.1\r\nHost: 127.0.0.1:3697\r\nX-DALI-Client: chrome-extension\r\n\r\n")
        XCTAssertTrue(request.authorizedControl)
        XCTAssertEqual(request.route, "/cut")
        XCTAssertNoThrow(try SyncHTTPRequest(header: "GET /resume HTTP/1.1\r\nOrigin: chrome-extension://abcdefghijklmnopabcdefghijklmnop\r\n\r\n"))
    }
    func testWebPagesCannotControlAudio() {
        for header in [
            "GET /cut HTTP/1.1\r\n\r\n",
            "GET /resume HTTP/1.1\r\nOrigin: https://example.com\r\nX-DALI-Client: chrome-extension\r\n\r\n",
            "OPTIONS /cut HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n",
            "GET /now HTTP/1.1\r\nOrigin: null\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: attacker.example:3697\r\n\r\n",
            "POST /cut HTTP/1.1\r\nX-DALI-Client: chrome-extension\r\n\r\n",
            "GET /cut HTTP/1.1\r\nOrigin: chrome-extension://invalid\r\n\r\n",
            "GET /cut HTTP/1.1\r\nX-DALI-Client: chrome-extension\r\nX-DALI-Client: chrome-extension\r\n\r\n"
        ] { XCTAssertThrowsError(try SyncHTTPRequest(header: header), header) }
    }
}
