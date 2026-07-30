import XCTest
@testable import LegadoRuleCore

final class HttpTTSEngineTests: XCTestCase {
    func testRenderURLSpeakTextPlaceholder() {
        let tpl = "https://tts.fixture.local/speak?text={{speakText}}&voice={{speakVoice}}"
        let cfg = HttpTTSConfig(url: tpl)
        let out = HttpTTSEngine.buildRequestURL(config: cfg, speakText: "你好世界", speakVoice: "zh")
        XCTAssertTrue(out.contains("text="))
        XCTAssertFalse(out.contains("{{speakText}}"))
    }

    func testIsDirectAudioURL() {
        XCTAssertTrue(HttpTTSEngine.isAudioURL("https://cdn.example/chapter.mp3"))
        XCTAssertTrue(HttpTTSEngine.isDirectAudioURL("file:///tmp/silence.m4a"))
        XCTAssertFalse(HttpTTSEngine.isAudioURL("https://example.com/chapter.html"))
    }

    func testResolveDirectAudioFromContent() {
        let url = HttpTTSEngine.resolveDirectAudioURL(
            chapterUrl: "https://book.example/ch1.html",
            content: "https://audio.example/ch1.mp3"
        )
        XCTAssertEqual(url, "https://audio.example/ch1.mp3")
    }

    func testResolveDirectAudioFromChapterUrl() {
        let url = HttpTTSEngine.resolveDirectAudioURL(
            chapterUrl: "https://audio.example/voice.m4a",
            content: nil
        )
        XCTAssertEqual(url, "https://audio.example/voice.m4a")
    }
}
