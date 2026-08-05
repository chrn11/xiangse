import XCTest
import JavaScriptCore
@testable import LegadoRuleCore
import LegadoObjCSupport

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

    /// 模拟 JavaScriptParser 注入：先装 result 函数（对齐 ExecutionContext 懒加载），再 delete+setObject
    func testOverwriteResultFunctionBinding() throws {
        let ctx = JSContext()!
        let bridge = JSBridge()
        bridge.injectLite(into: ctx)
        // 模拟 lazy jsContext 把 result 注成函数
        let getter: @convention(block) () -> String = { #"{"list":[{"title":"t1"},{"title":"t2"}]}"# }
        ctx.setObject(getter, forKeyedSubscript: "result" as NSString)
        ctx.globalObject?.setObject(getter, forKeyedSubscript: "result" as NSString)

        _ = ObjCExceptionCatch.evaluateScript("try { delete result; } catch (e) {}", in: ctx, error: nil)
        let raw = #"{"list":[{"title":"t1"},{"title":"t2"}]}"#
        ctx.setObject(raw, forKeyedSubscript: "result" as NSString)
        ctx.globalObject?.setObject(raw, forKeyedSubscript: "result" as NSString)
        ctx.setObject("https://example.com/x", forKeyedSubscript: "baseUrl" as NSString)

        let script = """
        function functionName(config, params, result) {
          result.list.shift();
          return { list: result.list, url: params.responseUrl || baseUrl };
        }
        """
        let out = try XiangseJSExecute.execute(
            script: script,
            in: ctx,
            extraParams: ["responseUrl": "https://example.com/x"]
        )
        XCTAssertTrue(out.contains("t2"), "实际: \(out)")
        XCTAssertFalse(out.contains("\"t1\""), "实际: \(out)")
        XCTAssertTrue(out.contains("example.com"), "实际: \(out)")
    }
}
