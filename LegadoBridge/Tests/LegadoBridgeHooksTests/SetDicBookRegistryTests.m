// TC-02：per-owner setDicBook: registry XCTest（待 macOS/iOS CI 执行；Windows 无 SDK）。
// fixture 类名/ABI 仅测例动态构造，不得当作当前 build 硬编码 owner。

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "LBHookSiteRegistry.h"

static NSInteger gBasePrevCalls;
static NSInteger gChildPrevCalls;
static NSInteger gInvokeCalls;
static NSDictionary *gLastPassBook;
static NSMutableArray<NSString *> *gDynamicClassNames;

static void LBTC02BaseOrig(id self, SEL _cmd, id book) {
    (void)self; (void)_cmd;
    gBasePrevCalls += 1;
    if ([book isKindOfClass:[NSDictionary class]]) {
        gLastPassBook = [book copy];
    } else {
        gLastPassBook = nil;
    }
}

static void LBTC02ChildOrig(id self, SEL _cmd, id book) {
    gChildPrevCalls += 1;
    Class superCls = class_getSuperclass(object_getClass(self));
    struct objc_super sup = { self, superCls };
    ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, _cmd, book);
}

static void LBTC02TestInvoke(id self, SEL sel, id book, LBSetDicBookIMP previous) {
    gInvokeCalls += 1;
    // 测例公共体：Legado 补 name；native 原样；nil 透传
    id pass = book;
    if ([book isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dic = (NSDictionary *)book;
        if ([dic[@"legadoBridge"] isEqual:@"1"] || [dic[@"legadoBridge"] isEqual:@1]) {
            NSMutableDictionary *m = [dic mutableCopy];
            if (![m[@"name"] isKindOfClass:[NSString class]] || [m[@"name"] length] == 0) {
                m[@"name"] = [m[@"bookName"] isKindOfClass:[NSString class]] ? m[@"bookName"] : @"书";
            }
            if (![m[@"bookName"] isKindOfClass:[NSString class]] || [m[@"bookName"] length] == 0) {
                m[@"bookName"] = m[@"name"] ?: @"书";
            }
            pass = m;
        }
    }
    if (previous) previous(self, sel, pass);
}

@interface SetDicBookRegistryTests : XCTestCase
@end

@implementation SetDicBookRegistryTests

+ (void)setUp {
    [super setUp];
    gDynamicClassNames = [NSMutableArray array];
}

- (NSString *)uniqueName:(NSString *)prefix {
    return [NSString stringWithFormat:@"%@_%u", prefix, arc4random()];
}

- (Class)makeClassNamed:(NSString *)name super:(Class)superCls addSetter:(BOOL)add withIMP:(IMP)imp {
    Class cls = objc_allocateClassPair(superCls, name.UTF8String, 0);
    XCTAssertNotNil(cls);
    if (add) {
        BOOL ok = class_addMethod(cls, @selector(setDicBook:), imp, "v24@0:8@16");
        XCTAssertTrue(ok);
    }
    objc_registerClassPair(cls);
    [gDynamicClassNames addObject:name];
    return cls;
}

- (void)tearDown {
    LBHookSiteRegistryResetForTests();
    gBasePrevCalls = 0;
    gChildPrevCalls = 0;
    gInvokeCalls = 0;
    gLastPassBook = nil;
    [super tearDown];
}

- (void)testDualOwnerChildCallsSuperMaxDepthOne {
    NSString *baseName = [self uniqueName:@"LBTC02Base"];
    NSString *childName = [self uniqueName:@"LBTC02Child"];
    Class base = [self makeClassNamed:baseName super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    Class child = [self makeClassNamed:childName super:base addSetter:YES withIMP:(IMP)LBTC02ChildOrig];

    XCTAssertEqual(LBHookSiteRegistryInstallSetDicBook(base, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL),
                   LBHookInstallResultInstalled);
    XCTAssertEqual(LBHookSiteRegistryInstallSetDicBook(child, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL),
                   LBHookInstallResultInstalled);
    XCTAssertEqual(LBHookSiteRegistryInstalledCount(), 2u);

    id inst = [[child alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(inst, @selector(setDicBook:), @{@"bookUrl": @"u"});

    XCTAssertEqual(gChildPrevCalls, 1);
    XCTAssertEqual(gBasePrevCalls, 1);
    XCTAssertEqual(LBHookSiteRegistryMaxDepthSeen(child, @selector(setDicBook:)), 1);
    XCTAssertEqual(LBHookSiteRegistryMaxDepthSeen(base, @selector(setDicBook:)), 1);
}

- (void)testOnlyHookBaseChildDoesNotOverride {
    NSString *baseName = [self uniqueName:@"LBTC02OnlyBase"];
    NSString *childName = [self uniqueName:@"LBTC02InheritChild"];
    Class base = [self makeClassNamed:baseName super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    Class child = [self makeClassNamed:childName super:base addSetter:NO withIMP:NULL];

    XCTAssertEqual(LBHookSiteRegistryInstallSetDicBook(base, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL),
                   LBHookInstallResultInstalled);
    XCTAssertEqual(LBHookSiteRegistryInstallSetDicBook(child, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL),
                   LBHookInstallResultNotDeclaringOwner);
    XCTAssertEqual(LBHookSiteRegistryInstalledCount(), 1u);

    id inst = [[child alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(inst, @selector(setDicBook:), @{@"k": @"v"});
    XCTAssertEqual(gBasePrevCalls, 1);
}

- (void)testIdempotentReinstall {
    NSString *name = [self uniqueName:@"LBTC02Idem"];
    Class cls = [self makeClassNamed:name super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    XCTAssertEqual(LBHookSiteRegistryInstallSetDicBook(cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL),
                   LBHookInstallResultInstalled);
    NSUInteger n = LBHookSiteRegistryInstalledCount();
    IMP prev = LBHookSiteRegistryPreviousIMP(cls, @selector(setDicBook:));
    IMP repl = LBHookSiteRegistryReplacementIMP(cls, @selector(setDicBook:));
    XCTAssertEqual(LBHookSiteRegistryInstallSetDicBook(cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL),
                   LBHookInstallResultAlreadyInstalled);
    XCTAssertEqual(LBHookSiteRegistryInstalledCount(), n);
    XCTAssertEqual(LBHookSiteRegistryPreviousIMP(cls, @selector(setDicBook:)), prev);
    XCTAssertEqual(LBHookSiteRegistryReplacementIMP(cls, @selector(setDicBook:)), repl);
}

- (void)testUnknownReplacementFailClosed {
    NSString *name = [self uniqueName:@"LBTC02Unknown"];
    Class cls = [self makeClassNamed:name super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    Method m = class_getInstanceMethod(cls, @selector(setDicBook:));
    // 植入未知 block stub
    IMP foreign = imp_implementationWithBlock(^void(id s, id b){ (void)s; (void)b; });
    method_setImplementation(m, foreign);
    NSString *reason = nil;
    LBHookInstallResult r = LBHookSiteRegistryInstallSetDicBook(
        cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, &reason);
    XCTAssertEqual(r, LBHookInstallResultFailClosed);
}

- (void)testABIMismatchSkipped {
    NSString *name = [self uniqueName:@"LBTC02BadABI"];
    Class cls = objc_allocateClassPair([NSObject class], name.UTF8String, 0);
    // 错误 encoding（无 object 参数偏移）
    class_addMethod(cls, @selector(setDicBook:), (IMP)LBTC02BaseOrig, "v16@0:8");
    objc_registerClassPair(cls);
    [gDynamicClassNames addObject:name];
    NSString *reason = nil;
    LBHookInstallResult r = LBHookSiteRegistryInstallSetDicBook(
        cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, &reason);
    XCTAssertEqual(r, LBHookInstallResultSkippedABI);
}

- (void)testNativeXBSByteEquivalent {
    NSString *name = [self uniqueName:@"LBTC02Native"];
    Class cls = [self makeClassNamed:name super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    LBHookSiteRegistryInstallSetDicBook(cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL);
    NSDictionary *book = @{@"sourceName": @"BookWorld", @"bookUrl": @"http://x", @"name": @"N"};
    id inst = [[cls alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(inst, @selector(setDicBook:), book);
    XCTAssertEqualObjects(gLastPassBook, book);
}

- (void)testLegadoEnrichment {
    NSString *name = [self uniqueName:@"LBTC02Legado"];
    Class cls = [self makeClassNamed:name super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    LBHookSiteRegistryInstallSetDicBook(cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL);
    NSDictionary *book = @{@"legadoBridge": @"1", @"bookUrl": @"u", @"sourceUrl": @"s"};
    id inst = [[cls alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(inst, @selector(setDicBook:), book);
    XCTAssertEqualObjects(gLastPassBook[@"name"], @"书");
    XCTAssertEqualObjects(gLastPassBook[@"bookName"], @"书");
}

- (void)testNilBookCallsPreviousOnce {
    NSString *name = [self uniqueName:@"LBTC02Nil"];
    Class cls = [self makeClassNamed:name super:[NSObject class] addSetter:YES withIMP:(IMP)LBTC02BaseOrig];
    LBHookSiteRegistryInstallSetDicBook(cls, LBSetDicBookExpectedEncodingABI, LBTC02TestInvoke, NULL);
    id inst = [[cls alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(inst, @selector(setDicBook:), nil);
    XCTAssertEqual(gBasePrevCalls, 1);
    XCTAssertNil(gLastPassBook);
}

@end
