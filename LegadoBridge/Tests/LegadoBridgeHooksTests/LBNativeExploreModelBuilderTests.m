#import <XCTest/XCTest.h>
#import "LBNativeExploreModelBuilder.h"

@interface LBNativeExploreModelBuilderTests : XCTestCase
@end

@implementation LBNativeExploreModelBuilderTests

- (NSData *)metaJSON:(NSDictionary *)obj {
    return [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
}

- (void)testBuildsSanitizedAdapterWithoutRawURL {
    NSDictionary *meta = @{
        @"schemaVersion": @1,
        @"sourceIdentityHash": @"src_abc",
        @"snapshotID": @"lbs1_deadbeef",
        @"state": @"ready",
        @"channels": @[
            @{
                @"channelID": @"lbc1_ch0",
                @"title": @"分组A",
                @"nodes": @[
                    @{@"nodeID": @"lbn1_n0", @"title": @"子项1", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n1", @"title": @"子项2", @"kind": @"url", @"selectable": @YES},
                ]
            }
        ]
    };
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:[self metaJSON:meta] error:&err];
    XCTAssertNil(err);
    XCTAssertEqualObjects(model[LBNativeExploreAdapterMarkerKey], @1);
    XCTAssertEqualObjects(model[@"schema"], LBNativeExploreAdapterSchema);
    XCTAssertEqualObjects(model[@"actionID"], LBNativeExploreStructureActionID);
    XCTAssertEqualObjects(model[@"parserID"], LBNativeExploreStructureParserID);
    NSArray *chs = model[@"channels"];
    XCTAssertEqual(chs.count, 1u);
    NSDictionary *ch0 = chs[0];
    XCTAssertEqualObjects([LBNativeExploreModelBuilder tagTitlesFromChannel:ch0], (@[@"子项1", @"子项2"]));
    XCTAssertEqualObjects([LBNativeExploreModelBuilder tagNodeIDsFromChannel:ch0], (@[@"lbn1_n0", @"lbn1_n1"]));
    NSString *blob = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:model options:0 error:nil]
                                           encoding:NSUTF8StringEncoding];
    XCTAssertFalse([blob containsString:@"http"]);
    XCTAssertFalse([blob.lowercaseString containsString:@"cookie"]);
    XCTAssertFalse([blob containsString:@"requestInfo"]);
}

- (void)testRejectsRawTargetInNode {
    NSDictionary *meta = @{
        @"schemaVersion": @1,
        @"sourceIdentityHash": @"src",
        @"snapshotID": @"lbs1_x",
        @"state": @"ready",
        @"channels": @[
            @{
                @"channelID": @"lbc1",
                @"title": @"A",
                @"nodes": @[
                    @{@"nodeID": @"n1", @"title": @"t", @"kind": @"url", @"selectable": @YES, @"url": @"/leak"}
                ]
            }
        ]
    };
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:[self metaJSON:meta] error:&err];
    XCTAssertNotNil(err);
    XCTAssertEqual(model.count, 0u);
}

- (void)testRejectsRequestInfoAtRoot {
    NSDictionary *meta = @{
        @"schemaVersion": @1,
        @"sourceIdentityHash": @"src",
        @"snapshotID": @"lbs1_x",
        @"state": @"ready",
        @"requestInfo": @"@js:leak",
        @"channels": @[]
    };
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:[self metaJSON:meta] error:&err];
    XCTAssertNotNil(err);
    XCTAssertEqual(model.count, 0u);
}

/// lingyu 形态：单 channel 多 URL node（无 raw target 渗入）。
- (void)testLingyuShapeSevenNodesOneChannel {
    NSDictionary *meta = @{
        @"schemaVersion": @1,
        @"sourceIdentityHash": @"abc123",
        @"snapshotID": @"lbs1_lingyu",
        @"state": @"ready",
        @"channels": @[
            @{
                @"channelID": @"lbc1_ch0",
                @"title": @"发现",
                @"nodes": @[
                    @{@"nodeID": @"lbn1_n0", @"title": @"玄幻奇幻", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n1", @"title": @"武侠仙侠", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n2", @"title": @"都市言情", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n3", @"title": @"历史军事", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n4", @"title": @"网游竞技", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n5", @"title": @"科幻灵异", @"kind": @"url", @"selectable": @YES},
                    @{@"nodeID": @"lbn1_n6", @"title": @"女生频道", @"kind": @"url", @"selectable": @YES},
                ]
            }
        ]
    };
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:[self metaJSON:meta] error:&err];
    XCTAssertNil(err);
    NSArray *chs = model[@"channels"];
    XCTAssertEqual(chs.count, 1u);
    XCTAssertEqual([LBNativeExploreModelBuilder tagTitlesFromChannel:chs[0]].count, 7u);
}

/// no-explore：空 channels + emptySuccess。
- (void)testNoExploreEmptySuccess {
    NSDictionary *meta = @{
        @"schemaVersion": @1,
        @"sourceIdentityHash": @"src",
        @"snapshotID": @"lbs1_empty",
        @"state": @"emptySuccess",
        @"channels": @[]
    };
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:[self metaJSON:meta] error:&err];
    XCTAssertNil(err);
    XCTAssertEqualObjects(model[@"state"], @"emptySuccess");
    XCTAssertEqual([(NSArray *)model[@"channels"] count], 0u);
}

- (void)testEmptyGroupChannelKeepsTitleNoTags {
    NSDictionary *meta = @{
        @"schemaVersion": @1,
        @"sourceIdentityHash": @"src",
        @"snapshotID": @"lbs1_empty",
        @"state": @"emptySuccess",
        @"channels": @[
            @{
                @"channelID": @"lbc1_empty",
                @"title": @"空分组",
                @"nodes": @[]
            }
        ]
    };
    NSError *err = nil;
    NSDictionary *model = [LBNativeExploreModelBuilder adapterModelFromMetadataJSON:[self metaJSON:meta] error:&err];
    XCTAssertNil(err);
    NSDictionary *ch0 = model[@"channels"][0];
    XCTAssertEqualObjects(ch0[@"title"], @"空分组");
    XCTAssertEqual([LBNativeExploreModelBuilder tagTitlesFromChannel:ch0].count, 0u);
}

@end
