import XCTest
@testable import Hark

final class MarkdownPlainTests: XCTestCase {
    func testHeadingPauses() {
        let out = MarkdownPlain.toSpeech("# 大标题\n\n正文段落。")
        XCTAssertEqual(out, "大标题……正文段落。")
    }

    func testListSemicolons() {
        let out = MarkdownPlain.toSpeech("- 第一项\n- 第二项")
        XCTAssertEqual(out, "第一项；第二项；")
    }

    func testInlineFormattingStripped() {
        let out = MarkdownPlain.toSpeech("这是 **加粗** 和 `代码` 与 [链接](https://x.com)。")
        XCTAssertEqual(out, "这是 加粗 和 代码 与 链接。")
    }

    func testCodeFenceSkipped() {
        // 围栏关闭补一个句号停顿，joinPause 会把连续句号折叠为一个
        let out = MarkdownPlain.toSpeech("前文。\n```\ncode = 1\n```\n后文。")
        XCTAssertEqual(out, "前文。后文。")
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownPlain.toSpeech("   \n  "), "")
    }
}

final class TtsServiceTests: XCTestCase {
    func testEdgeRateToFloat() {
        XCTAssertEqual(TtsService.edgeRateToFloat("+0%"), 1.0)
        XCTAssertEqual(TtsService.edgeRateToFloat("-50%"), 0.5)
        XCTAssertEqual(TtsService.edgeRateToFloat("+100%"), 2.0)
        XCTAssertEqual(TtsService.edgeRateToFloat("-80%"), 0.5)
        XCTAssertEqual(TtsService.edgeRateToFloat("bogus"), 1.0)
    }

    func testPythonStrEscapes() {
        XCTAssertEqual(TtsService.pythonStr("hi"), #""hi""#)
        XCTAssertEqual(TtsService.pythonStr("he said \"ok\""), "\"he said \\\"ok\\\"\"")
        XCTAssertEqual(TtsService.pythonStr("中文"), "\"中文\"")
    }

    func testCosyVoiceVoiceList() {
        XCTAssertTrue(TtsService.cosyVoiceList.contains { $0.id == "longxiaochun" })
    }
}
