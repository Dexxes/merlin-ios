import XCTest
@testable import MerlinShared

final class ReadInMerlinLinkTests: XCTestCase {

    func testRoundTripKeepsQueryAndFragment() throws {
        let article = "https://example.com/a/b?x=1&y=two+three&z=%C3%A4#teil-2"
        let link = try XCTUnwrap(ReadInMerlinLink.deepLink(for: article))
        XCTAssertEqual(link.scheme, "merlin")
        XCTAssertEqual(link.host, "read")
        XCTAssertEqual(ReadInMerlinLink.articleURL(from: link), article)
    }

    func testDeepLinkTrimsWhitespace() throws {
        let link = try XCTUnwrap(ReadInMerlinLink.deepLink(for: "  https://example.com/x \n"))
        XCTAssertEqual(ReadInMerlinLink.articleURL(from: link), "https://example.com/x")
    }

    func testRejectsNonWebURLs() {
        XCTAssertNil(ReadInMerlinLink.deepLink(for: "file:///tmp/a.pdf"))
        XCTAssertNil(ReadInMerlinLink.deepLink(for: "mailto:a@example.com"))
        XCTAssertNil(ReadInMerlinLink.deepLink(for: "not a url"))
        XCTAssertNil(ReadInMerlinLink.articleURL(from: URL(string: "merlin://read?url=javascript:alert(1)")!))
    }

    func testIgnoresOtherLinks() {
        XCTAssertNil(ReadInMerlinLink.articleURL(from: URL(string: "https://example.com/read?url=https://a.b")!))
        XCTAssertNil(ReadInMerlinLink.articleURL(from: URL(string: "merlin://other?url=https://a.b")!))
        XCTAssertNil(ReadInMerlinLink.articleURL(from: URL(string: "merlin://read")!))
    }
}
