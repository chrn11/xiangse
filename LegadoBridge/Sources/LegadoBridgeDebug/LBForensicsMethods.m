#import "LBForensics.h"
#import <objc/runtime.h>

extern NSString *LBForensicsPointer(id obj);

#pragma mark - Method owner resolution (class_copyMethodList, no string proximity)

static Class LBFMethodOwnerForSelector(Class startCls, SEL sel) {
    Class cls = startCls;
    while (cls) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        BOOL found = NO;
        if (methods) {
            for (unsigned int i = 0; i < count; i++) {
                if (sel == method_getName(methods[i])) {
                    found = YES;
                    break;
                }
            }
            free(methods);
        }
        if (found) return cls;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static NSArray<NSString *> *LBFReaderRelatedSelectors(void) {
    return @[
        @"viewDidLoad",
        @"viewWillAppear:",
        @"loadCurCp",
        @"onResetContentNotify",
        @"onResetContentNotify:",
        @"onResetContent:",
        @"resetContentNotify:",
        @"handleResetContent:",
        @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:",
        @"divisionText:cpTitle:cpIndex:tvSize:doubleCol:backHeights:paibanInfo:",
        @"divisionResponse:cpTitle:cpIndex:",
        @"divisionResponse:cpTitle:cpIndex:heights:",
        @"onDivisionTextFinish:cpIndex:",
        @"drawRect:",
        @"resetContentPosByScreenSize:",
        @"showContent:",
        @"showContent:title:",
        @"setPageModel:",
        @"reloadContent",
        @"reloadView",
        @"refreshView",
    ];
}

static NSArray<NSString *> *LBFProbeClassNames(void) {
    NSMutableArray *names = [NSMutableArray arrayWithArray:LBForensicsCandidateClassNames()];
    [names addObjectsFromArray:@[
        @"TextReadVC2", @"TextReadVC1",
        @"ReadVCBase2", @"ReadVCBase1",
        @"TextReadTVBase",
        @"TextRScrollContainerCell",
    ]];
    return names;
}

static NSDictionary *LBFDumpClassMethodLayer(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *rows = [NSMutableArray array];
    if (methods) {
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            const char *enc = method_getTypeEncoding(methods[i]);
            IMP imp = method_getImplementation(methods[i]);
            [rows addObject:@{
                @"selector": NSStringFromSelector(sel),
                @"typeEncoding": enc ? [NSString stringWithUTF8String:enc] : @"?",
                @"imp": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)imp],
                @"ownerClass": NSStringFromClass(cls),
            }];
        }
        free(methods);
    }
    return @{
        @"class": NSStringFromClass(cls),
        @"methodCount": @(rows.count),
        @"methods": rows,
    };
}

NSDictionary *LBForensicsBuildMethodOwners(void) {
    NSMutableArray *resolved = [NSMutableArray array];
    NSMutableArray *unresolved = [NSMutableArray array];
    NSMutableDictionary *layersByClass = [NSMutableDictionary dictionary];

    for (NSString *selName in LBFReaderRelatedSelectors()) {
        SEL sel = NSSelectorFromString(selName);
        BOOL any = NO;
        for (NSString *cn in LBFProbeClassNames()) {
            Class cls = NSClassFromString(cn);
            if (!cls) continue;
            Class owner = LBFMethodOwnerForSelector(cls, sel);
            if (!owner) continue;
            Method m = class_getInstanceMethod(owner, sel);
            if (!m) continue;
            any = YES;
            const char *enc = method_getTypeEncoding(m);
            IMP imp = method_getImplementation(m);
            [resolved addObject:@{
                @"probeClass": cn,
                @"ownerClass": NSStringFromClass(owner),
                @"selector": selName,
                @"typeEncoding": enc ? [NSString stringWithUTF8String:enc] : @"?",
                @"imp": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)imp],
            }];
        }
        if (!any) [unresolved addObject:selName];
    }

    for (NSString *cn in LBFProbeClassNames()) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        NSMutableArray *layers = [NSMutableArray array];
        Class walk = cls;
        int depth = 0;
        while (walk && walk != [NSObject class] && depth < 32) {
            [layers addObject:LBFDumpClassMethodLayer(walk)];
            walk = class_getSuperclass(walk);
            depth++;
        }
        layersByClass[cn] = layers;
    }

    return @{
        @"readerSelectors": resolved,
        @"unresolvedSelectors": unresolved,
        @"classMethodLayers": layersByClass,
    };
}

NSString *LBForensicsBuildMethodOwnersText(NSDictionary *methods) {
    NSMutableString *out = [NSMutableString stringWithString:@"=== method owners ===\n"];
    for (NSDictionary *row in methods[@"readerSelectors"]) {
        [out appendFormat:@"%@ %@ enc=%@ imp=%@\n",
         row[@"ownerClass"], row[@"selector"], row[@"typeEncoding"], row[@"imp"]];
    }
    NSArray *unres = methods[@"unresolvedSelectors"];
    if (unres.count) {
        [out appendFormat:@"\nunresolved: %@\n", [unres componentsJoinedByString:@", "]];
    }
    return out;
}

Class LBForensicsMethodOwnerClass(Class cls, SEL sel) {
    return LBFMethodOwnerForSelector(cls, sel);
}
