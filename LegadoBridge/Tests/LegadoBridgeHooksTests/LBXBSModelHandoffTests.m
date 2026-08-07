#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "LBXBSModelHandoff.h"

@interface LBMockBookWorldHost : UIViewController {
@public
    NSDictionary *_dicModel;
}
@end
@implementation LBMockBookWorldHost
@end

@interface LBXBSModelHandoffTests : XCTestCase
@end

@implementation LBXBSModelHandoffTests

- (NSDictionary *)completeModel {
    return @{
        @"cf_title": @"番茄小说",
        @"bookWorld": @{
            @"推荐": @{
                @"actionID": @"bookWorld",
                @"parserID": @"dom1",
                @"requestInfo": @"@js:/*redacted*/",
                @"list": @[],
            }
        }
    };
}

- (NSDictionary *)missingRequestModel {
    return @{
        @"bookWorld": @{
            @"推荐": @{
                @"actionID": @"bookWorld",
                @"parserID": @"dom1",
                @"list": @[],
            }
        }
    };
}

- (NSDictionary *)missingListModel {
    return @{
        @"bookWorld": @{
            @"推荐": @{
                @"actionID": @"bookWorld",
                @"parserID": @"dom1",
                @"requestInfo": @"x",
            }
        }
    };
}

- (void)testValidateAcceptsCompleteBookWorld {
    XCTAssertEqual(LBValidateXBSModelShape([self completeModel], @"番茄小说", nil), LBXBSModelValidateValid);
}

- (void)testRejectsLegadoProjection {
    NSDictionary *m = @{@"legadoBridge": @"1", @"bookWorld": @{}};
    XCTAssertEqual(LBValidateXBSModelShape(m, nil, nil), LBXBSModelValidateLegadoProjection);
}

- (void)testRejectsAdapterMarker {
    NSDictionary *m = @{@"_lb_adapter": @1, @"bookWorld": @{}};
    XCTAssertEqual(LBValidateXBSModelShape(m, nil, nil), LBXBSModelValidateLegadoProjection);
}

- (void)testRejectsThinShell {
    NSDictionary *m = @{@"a": @1, @"b": @2};
    XCTAssertEqual(LBValidateXBSModelShape(m, nil, nil), LBXBSModelValidateThinBridgeShell);
}

- (void)testRejectsMissingAction {
    NSDictionary *m = @{
        @"bookWorld": @{
            @"推荐": @{
                @"parserID": @"dom1",
                @"requestInfo": @"x",
                @"list": @[],
            }
        }
    };
    XCTAssertEqual(LBValidateXBSModelShape(m, nil, nil), LBXBSModelValidateMissingAction);
}

- (void)testRejectsMissingRequest {
    XCTAssertEqual(LBValidateXBSModelShape([self missingRequestModel], nil, nil), LBXBSModelValidateMissingRequest);
}

- (void)testRejectsMissingList {
    XCTAssertEqual(LBValidateXBSModelShape([self missingListModel], nil, nil), LBXBSModelValidateMissingList);
}

- (void)testHandoffWritesAndReadbackValid {
    LBMockBookWorldHost *host = [LBMockBookWorldHost new];
    NSError *err = nil;
    BOOL ok = LBXBSHandoffWriteHostDicModel(host, [self completeModel], @"番茄小说", &err);
    XCTAssertTrue(ok, @"%@", err);
    XCTAssertEqual(LBValidateXBSModelShape(host->_dicModel, @"番茄小说", nil), LBXBSModelValidateValid);
}

- (void)testHandoffNoOpWhenHostAlreadyValid {
    LBMockBookWorldHost *host = [LBMockBookWorldHost new];
    NSDictionary *original = [self completeModel];
    host->_dicModel = original;
    NSError *err = nil;
    BOOL ok = LBXBSHandoffWriteHostDicModel(host, [self completeModel], @"番茄小说", &err);
    XCTAssertTrue(ok);
    XCTAssertEqual(host->_dicModel, original);
}

- (void)testHandoffFailClosedOnNilHost {
    NSError *err = nil;
    BOOL ok = LBXBSHandoffWriteHostDicModel(nil, [self completeModel], @"k", &err);
    XCTAssertFalse(ok);
    XCTAssertNotNil(err);
}

- (void)testHandoffRejectsInvalidModel {
    LBMockBookWorldHost *host = [LBMockBookWorldHost new];
    NSError *err = nil;
    BOOL ok = LBXBSHandoffWriteHostDicModel(host, [self missingListModel], @"k", &err);
    XCTAssertFalse(ok);
    XCTAssertNotNil(err);
}

@end
