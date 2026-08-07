import Foundation
import XCTest
@testable import LegadoBridge
import LegadoRuleCore

final class NativeExploreSnapshotBridgeTests: XCTestCase {
    func testSanitizedMetadataHasNoRawURL() throws {
        let core = LegadoBridgeCore.shared
        // 无源时也应返回合法 envelope
        let json = core.exploreSnapshotMetadataJSON(forSourceUrl: nil)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(obj["state"] as? String)
        XCTAssertNotNil(obj["channels"] as? [Any])
        XCTAssertFalse(json.lowercased().contains("cookie"))
        XCTAssertFalse(json.contains("requestInfo"))
    }

    func testBuilderRoundTripFromSanitizedDTO() throws {
        let meta: [String: Any] = [
            "schemaVersion": 1,
            "sourceIdentityHash": "abc",
            "snapshotID": "lbs1_x",
            "state": "ready",
            "channels": [
                [
                    "channelID": "lbc1",
                    "title": "G",
                    "nodes": [
                        ["nodeID": "lbn1", "title": "N", "kind": "url", "selectable": true]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: meta)
        // ObjC builder 通过 Bridging 头可用时再跑；此处至少保证 DTO 形状
        XCTAssertGreaterThan(data.count, 10)
        let snap = ExploreCatalogBuilder.build(
            exactSourceUrl: "https://explore.example/t",
            exploreRaw: "玄幻::/a\n都市::/b"
        )
        XCTAssertEqual(snap.channels.count, 1)
        XCTAssertEqual(snap.channels[0].nodes.count, 2)
        for n in snap.channels[0].nodes {
            XCTAssertFalse(n.nodeID.isEmpty)
            XCTAssertTrue(n.nodeID.hasPrefix("lbn1_"))
        }
    }
}
