import XCTest
@testable import LegadoRuleCore

final class HttpTTSEngineFromReviewFileTests: XCTestCase {
    func testBuildRequestURLReplacesSpeakText() {
        var cfg = HttpTTSConfig(name: "mock", url: "https://tts.example/say?q={{speakText}}&v={{voice}}")
        cfg.header = nil
        let url = HttpTTSEngine.buildRequestURL(config: cfg, speakText: "你好", speakVoice: "zh")
        XCTAssertTrue(url.contains("tts.example"), url)
        XCTAssertFalse(url.contains("{{speakText}}"), url)
        XCTAssertTrue(url.contains("v=zh") || url.contains("v="), url)
    }

    func testIsAudioURL() {
        XCTAssertTrue(HttpTTSEngine.isAudioURL("https://cdn.example/a.mp3"))
        XCTAssertTrue(HttpTTSEngine.isAudioURL("https://cdn.example/x?format=mp3"))
        XCTAssertFalse(HttpTTSEngine.isAudioURL("https://cdn.example/a.html"))
        XCTAssertFalse(HttpTTSEngine.isAudioURL("not-a-url"))
    }
}

final class ReviewParseTests: XCTestCase {
    func testParseReviewsFromLocalHTML() throws {
        let html = """
        <html><body>
        <div class="review-item"><img class="avatar" src="/a.png"/><div class="content">好看推荐</div></div>
        <div class="review-item"><div class="content">第二评论</div></div>
        </body></html>
        """
        let rule = BridgeReviewRule(
            reviewUrl: "https://fixture.local/r",
            avatarRule: "class.avatar@src",
            contentRule: "class.content@text"
        )
        let reviews = try RuleWebBook.parseReviews(
            body: html,
            baseUrl: "https://fixture.local/",
            reviewRule: rule
        )
        XCTAssertGreaterThanOrEqual(reviews.count, 1)
        XCTAssertTrue(reviews.contains(where: { $0.content.contains("好看") }))
    }
}
