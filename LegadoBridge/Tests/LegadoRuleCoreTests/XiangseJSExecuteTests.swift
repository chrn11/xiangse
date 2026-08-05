import XCTest
import JavaScriptCore
@testable import LegadoRuleCore

/// 香色 JSParser 三参后处理
final class XiangseJSExecuteTests: XCTestCase {

    func testDetectsFunctionName() {
        XCTAssertTrue(XiangseJSExecute.looksLikeXiangseFunction("""
        function functionName(config, params, result) {
          return result;
        }
        """))
        XCTAssertFalse(XiangseJSExecute.looksLikeXiangseFunction("result = 1;"))
        XCTAssertFalse(XiangseJSExecute.looksLikeXiangseFunction("function foo(a,b){return a;}"))
    }

    func testThreeArgReturnObject() throws {
        let ctx = JSContext()!
        let bridge = JSBridge()
        bridge.injectLite(into: ctx)
        ctx.evaluateScript(#"var result = {"list":[{"title":"t1"},{"title":"t2"},{"title":"t3"}]};"#)

        let script = """
        function functionName(config,params,result){
          for(let i=0;i<1;i++){ result.list.shift(); }
          return {"list":result.list};
        }
        """
        let out = try XiangseJSExecute.execute(
            script: script,
            in: ctx,
            config: ["k": "v"],
            extraParams: ["responseUrl": "https://example.com/toc"]
        )
        XCTAssertTrue(out.contains("t2"), "应去掉首项，实际: \(out)")
        XCTAssertTrue(out.contains("t3"), "实际: \(out)")
        XCTAssertFalse(out.contains("\"t1\""), "t1 应被 shift 掉，实际: \(out)")
    }

    func testPromoteJSONStringResult() throws {
        let ctx = JSContext()!
        let bridge = JSBridge()
        bridge.injectLite(into: ctx)
        ctx.evaluateScript(#"var result = '{"posts":[{"title":"A","likeCount":1}]}';"#)

        let script = """
        function functionName(config, params, result) {
          return { list: result.posts.map(function(p){ return { title: p.title }; }) };
        }
        """
        let out = try XiangseJSExecute.execute(script: script, in: ctx)
        XCTAssertTrue(out.contains("A"), "实际: \(out)")
    }

    func testNativeToolInsideParams() throws {
        let ctx = JSContext()!
        let bridge = JSBridge()
        bridge.injectLite(into: ctx)
        ctx.evaluateScript("var result = 'abc';")

        let script = """
        function functionName(config, params, result) {
          return { md5: params.nativeTool.md5Encode(result) };
        }
        """
        let out = try XiangseJSExecute.execute(script: script, in: ctx)
        XCTAssertTrue(
            out.contains("900150983cd24fb0d6963f7d28e17f72"),
            "实际: \(out)"
        )
    }

    func testJavaScriptParserPath() throws {
        let engine = RuleEngine()
        let context = ExecutionContext()
        context.ruleEngine = engine
        context.document = #"{"list":[{"title":"t1"},{"title":"t2"}]}"#
        context.baseURL = URL(string: "https://example.com/x")
        let rule = #"""
        @js:
        function functionName(config, params, result) {
          if (!result || !result.list) {
            return { err: "bad-result", t: typeof result, v: String(result).slice(0,80) };
          }
          result.list.shift();
          return { list: result.list, url: params.responseUrl };
        }
        """#
        let parser = JavaScriptParser()
        let result: RuleResult
        do {
            result = try parser.execute(rule, context: context)
        } catch {
            XCTFail("JavaScriptParser 抛错: \(error)")
            return
        }
        guard case .string(let s) = result else {
            XCTFail("应为 string，实际 \(result)")
            return
        }
        XCTAssertFalse(s.contains("bad-result"), "result 未正确注入: \(s)")
        XCTAssertTrue(s.contains("t2"), "实际: \(s)")
        XCTAssertFalse(s.contains("\"t1\""), "实际: \(s)")
        XCTAssertTrue(s.contains("example.com"), "应带 responseUrl，实际: \(s)")
    }
}
