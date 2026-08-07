import XCTest
@testable import LegadoBridge

/// TC-10：Release 诊断脱敏零泄漏 fixtures。
final class BridgeDiagnosticRedactorTests: XCTestCase {
    private let secretURL = "https://fanqienovel.com/api/book?id=12345&token=SECRET"
    private let secretCookie = "sessionid=abc123SECRET; uid=42"
    private let secretAuth = "Bearer eyJhbGciOiJIUzI1NiJ9.payload"
    private let secretTitle = "绝密书名《测试》"
    private let secretPath = "/var/mobile/Containers/Data/Application/DEADBEEF/Documents/book.cache"

    func testSourceRedactionNoPlaintextLeak() {
        let line = BridgeDiagnosticRedactor.redact(
            .source(url: secretURL, name: "显示名")
        ).compactLine(tag: "src")
        XCTAssertFalse(line.contains("fanqienovel"))
        XCTAssertFalse(line.contains("SECRET"))
        XCTAssertFalse(line.contains("显示名"))
        XCTAssertTrue(line.contains("sourceUrlHash="))
    }

    func testBookRedactionNoTitleOrPathLeak() {
        let line = BridgeDiagnosticRedactor.redact(
            .book(title: secretTitle, author: "作者甲", containerPath: secretPath)
        ).compactLine(tag: "book")
        let leaks = BridgeDiagnosticRedactor.containsLeak(line, forbidden: [
            secretTitle, "作者甲", secretPath, "DEADBEEF",
        ])
        XCTAssertTrue(leaks.isEmpty, "leaks: \(leaks)")
        XCTAssertTrue(line.contains("bookTitleHash="))
    }

    func testRequestRedactionNoCookieOrAuthLeak() {
        let line = BridgeDiagnosticRedactor.redact(
            .request(
                url: secretURL,
                query: ["token": "SECRET", "page": "1"],
                cookie: secretCookie,
                authHeader: secretAuth
            )
        ).compactLine(tag: "req")
        let leaks = BridgeDiagnosticRedactor.containsLeak(line, forbidden: [
            secretURL, secretCookie, secretAuth, "sessionid", "Bearer", "SECRET",
        ])
        XCTAssertTrue(leaks.isEmpty, "leaks: \(leaks)")
        XCTAssertTrue(line.contains("cookieByteCount="))
        XCTAssertTrue(line.contains("authPresent=1"))
        XCTAssertTrue(line.contains("requestQueryKeyCount=2"))
    }

    func testChapterAndErrorFieldsBounded() {
        let ch = BridgeDiagnosticRedactor.redact(.chapter(index: 7, title: secretTitle))
            .compactLine(tag: "ch")
        XCTAssertTrue(ch.contains("chapterIndex=7"))
        XCTAssertFalse(ch.contains(secretTitle))

        let err = BridgeDiagnosticRedactor.redact(
            .error(domain: "NSURLErrorDomain", code: -1009, description: secretURL)
        ).compactLine(tag: "err")
        XCTAssertTrue(err.contains("errorDomain=NSURLErrorDomain"))
        XCTAssertTrue(err.contains("errorCode=-1009"))
        XCTAssertFalse(err.contains(secretURL))
    }

    func testGenerationOnlyOutputsCounter() {
        let line = BridgeDiagnosticRedactor.redact(.generation(42)).compactLine(tag: "gen")
        XCTAssertEqual(line.trimmingCharacters(in: .whitespacesAndNewlines), "gen generation=42")
    }
}
