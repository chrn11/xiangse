import XCTest
@testable import LegadoRuleCore

final class ReviewFetchTests: XCTestCase {
    private let html = """
    <html><body>
    <div class="review-item">
      <img class="avatar" src="/avatars/u1.jpg"/>
      <p class="content">第一章写得很精彩</p>
    </div>
    <div class="review-item">
      <img class="avatar" src="https://fixture.local/a2.png"/>
      <p class="content">期待更新</p>
    </div>
    </body></html>
    """

    func testParseReviewsFromFixtureBody() throws {
        let rule = BridgeReviewRule(
            reviewUrl: "https://fixture.local/reviews.html",
            avatarRule: "class.avatar@src",
            contentRule: "class.content@text"
        )
        let reviews = try RuleWebBook.parseReviews(
            body: html,
            baseUrl: "https://fixture.local/",
            reviewRule: rule
        )
        XCTAssertGreaterThanOrEqual(reviews.count, 1)
        XCTAssertTrue(reviews.contains { $0.content.contains("精彩") || $0.content.contains("更新") })
    }
}
