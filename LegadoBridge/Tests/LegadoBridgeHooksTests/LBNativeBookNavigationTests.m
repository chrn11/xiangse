#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LBNativeBookNavigation.h"

static NSMutableArray<NSString *> *gNavOrder;
static NSInteger gCreateCount;
static NSInteger gSetDicCount;
static NSInteger gSetKeyCount;
static NSInteger gPushCount;

@interface LBFakeBookDetailController : UIViewController
@property (nonatomic, copy) NSDictionary *dicBook;
@property (nonatomic, copy) NSString *bookKey;
+ (instancetype)create;
- (void)setDicBook:(NSDictionary *)dic;
- (void)setBookKey:(NSString *)key;
@end

@implementation LBFakeBookDetailController
+ (instancetype)create {
    gCreateCount += 1;
    [gNavOrder addObject:@"create"];
    return [[self alloc] init];
}
- (void)setDicBook:(NSDictionary *)dic {
    gSetDicCount += 1;
    [gNavOrder addObject:@"setDicBook"];
    _dicBook = [dic copy];
}
- (void)setBookKey:(NSString *)key {
    gSetKeyCount += 1;
    [gNavOrder addObject:@"setBookKey"];
    _bookKey = [key copy];
}
@end

@interface LBFakeNavHost : UIViewController
@property (nonatomic, strong) UINavigationController *forcedNav;
@end
@implementation LBFakeNavHost
- (UINavigationController *)navigationController {
    return self.forcedNav;
}
@end

@interface LBCountingNav : UINavigationController
@end
@implementation LBCountingNav
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    gPushCount += 1;
    [gNavOrder addObject:@"push"];
    [super pushViewController:viewController animated:animated];
}
@end

@interface LBNativeBookNavigationTests : XCTestCase
@end

@implementation LBNativeBookNavigationTests

- (void)setUp {
    [super setUp];
    gNavOrder = [NSMutableArray array];
    gCreateCount = gSetDicCount = gSetKeyCount = gPushCount = 0;
    LBNativeNavResetPushGuardForTests();
    LBNativeNavSetDetailClassNameForTests(NSStringFromClass([LBFakeBookDetailController class]));
    LBNativeNavSetSkipUpsertForTests(YES);
}

- (void)tearDown {
    LBNativeNavSetDetailClassNameForTests(nil);
    LBNativeNavSetSkipUpsertForTests(NO);
    LBNativeNavResetPushGuardForTests();
    [super tearDown];
}

- (NSDictionary *)legadoBook {
    return @{
        @"legadoBridge": @"1",
        @"fromLegadoBridge": @YES,
        @"bookUrl": @"https://example.com/book/1",
        @"sourceUrl": @"https://example.com/source",
        @"name": @"测书",
        @"author": @"作者",
        @"legadoBridgeToken":
            @"lb2_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
}

- (void)testMultiSourceCoexistenceUnsupported {
    XCTAssertFalse(LBNativeShelfMultiSourceCoexistenceSupported());
}

- (void)testBookKeyFailClosedWithoutAppConfig {
    // 单测环境通常无 AppConfig → nil
    NSString *k = LBNativeBookKeyForDictionary(@{@"bookName": @"a", @"author": @"b"});
    // 若宿主碰巧有 AppConfig 则非 nil；否则必须 nil（不得自制 | 拼接）
    if (k != nil) {
        XCTAssertFalse([k containsString:@"|"]);
    }
}

- (void)testRejectsMissingMarker {
    LBFakeNavHost *host = [LBFakeNavHost new];
    host.forcedNav = [[LBCountingNav alloc] initWithRootViewController:host];
    gPushCount = 0; // initWithRootViewController 可能内部 push，与业务 push 分开计数
    NSError *err = nil;
    NSDictionary *book = @{
        @"bookUrl": @"https://a/b",
        @"sourceUrl": @"https://s",
    };
    XCTAssertFalse(LBOpenLegadoBookDetail(host, book, @"search", &err));
    XCTAssertEqual(err.code, LBNativeBookNavigationErrorMissingBridgeMarker);
    XCTAssertEqual(gPushCount, 0);
}

- (void)testRejectsMissingPair {
    LBFakeNavHost *host = [LBFakeNavHost new];
    host.forcedNav = [[LBCountingNav alloc] initWithRootViewController:host];
    gPushCount = 0;
    NSError *err = nil;
    NSDictionary *book = @{@"legadoBridge": @"1", @"bookUrl": @"https://a/b"};
    XCTAssertFalse(LBOpenLegadoBookDetail(host, book, @"search", &err));
    XCTAssertEqual(err.code, LBNativeBookNavigationErrorMissingPair);
}

- (void)testRejectsNativeOrXBSRow {
    LBFakeNavHost *host = [LBFakeNavHost new];
    host.forcedNav = [[LBCountingNav alloc] initWithRootViewController:host];
    gPushCount = 0;
    NSError *err = nil;
    NSDictionary *book = @{
        @"_lb_sourceType": @"native",
        @"bookUrl": @"https://example.com/book/1",
        @"sourceUrl": @"https://example.com/source",
    };
    XCTAssertFalse(LBOpenLegadoBookDetail(host, book, @"search", &err));
    XCTAssertEqual(err.code, LBNativeBookNavigationErrorNativeOrXBSRow);
    XCTAssertEqual(gPushCount, 0);
}

- (void)testRejectsInvalidToken {
    LBFakeNavHost *host = [LBFakeNavHost new];
    host.forcedNav = [[LBCountingNav alloc] initWithRootViewController:host];
    gPushCount = 0;
    NSMutableDictionary *book = [[self legadoBook] mutableCopy];
    book[@"legadoBridgeToken"] = @"not-a-token";
    NSError *err = nil;
    XCTAssertFalse(LBOpenLegadoBookDetail(host, book, @"search", &err));
    XCTAssertEqual(err.code, LBNativeBookNavigationErrorInvalidToken);
}

- (void)testCreateSetDicSetKeyPushOrder {
    LBFakeNavHost *host = [LBFakeNavHost new];
    LBCountingNav *nav = [[LBCountingNav alloc] initWithRootViewController:host];
    host.forcedNav = nav;
    gPushCount = 0;
    gNavOrder = [NSMutableArray array];
    gCreateCount = gSetDicCount = gSetKeyCount = 0;
    NSError *err = nil;
    XCTAssertTrue(LBOpenLegadoBookDetail(host, [self legadoBook], @"BookListCon.didSelect", &err),
                  @"%@", err);
    XCTAssertEqual(gCreateCount, 1);
    XCTAssertEqual(gSetDicCount, 1);
    XCTAssertEqual(gSetKeyCount, 1);
    XCTAssertEqual(gPushCount, 1);
    XCTAssertEqualObjects(gNavOrder, (@[@"create", @"setDicBook", @"setBookKey", @"push"]));
    UIViewController *top = nav.topViewController;
    XCTAssertTrue([top isKindOfClass:[LBFakeBookDetailController class]]);
}

- (void)testDoublePushBlocked {
    LBFakeNavHost *host = [LBFakeNavHost new];
    host.forcedNav = [[LBCountingNav alloc] initWithRootViewController:host];
    gPushCount = 0;
    NSError *err1 = nil;
    NSError *err2 = nil;
    XCTAssertTrue(LBOpenLegadoBookDetail(host, [self legadoBook], @"search", &err1));
    XCTAssertFalse(LBOpenLegadoBookDetail(host, [self legadoBook], @"search", &err2));
    XCTAssertEqual(err2.code, LBNativeBookNavigationErrorDoublePushBlocked);
    XCTAssertEqual(gPushCount, 1);
}

- (void)testStackUnchangedOnFailure {
    LBFakeNavHost *host = [LBFakeNavHost new];
    LBCountingNav *nav = [[LBCountingNav alloc] initWithRootViewController:host];
    host.forcedNav = nav;
    NSUInteger before = nav.viewControllers.count;
    NSError *err = nil;
    XCTAssertFalse(LBOpenLegadoBookDetail(host, @{@"legadoBridge": @"1"}, @"x", &err));
    XCTAssertEqual(nav.viewControllers.count, before);
}

@end
