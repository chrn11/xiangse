#import "LBForensics.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

const NSInteger LBForensicsDumpSchemaVersion = 2;

static NSString *LBForensicsUTCNow(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    return [fmt stringFromDate:[NSDate date]];
}

static NSString *LBForensicsFileStamp(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    fmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    return [fmt stringFromDate:[NSDate date]];
}

NSString *LBForensicsPointer(id obj) {
    if (!obj) return @"0x0";
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)(uintptr_t)(__bridge void *)obj];
}

static NSString *LBForensicsManifestSHA(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    NSString *manifestPath = [docs stringByAppendingPathComponent:@"reader-build-manifest.json"];
    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    if (!data.length) {
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"reader-build-manifest" ofType:@"json"];
        data = bundlePath ? [NSData dataWithContentsOfFile:bundlePath] : nil;
    }
    if (!data.length) return @"unknown";
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return @"unknown";
    NSDictionary *m = (NSDictionary *)json;
    NSString *sha = m[@"legado_debug_sha256"];
    if (![sha isKindOfClass:[NSString class]] || sha.length < 8) {
        sha = m[@"app_binary_sha256"];
    }
    if (![sha isKindOfClass:[NSString class]] || sha.length < 8) return @"unknown";
    return [sha substringToIndex:8];
}

static NSString *LBForensicsDocumentsDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *LBForensicsSafeClassName(id obj) {
    if (!obj) return @"(null)";
    return NSStringFromClass(object_getClass(obj)) ?: @"?";
}

static NSString *LBForensicsDescribeValueShape(id val) {
    if (!val) return @"null";
    if ([val isKindOfClass:[NSNull class]]) return @"null";
    if ([val isKindOfClass:[NSString class]]) {
        return [NSString stringWithFormat:@"NSString len=%lu", (unsigned long)[(NSString *)val length]];
    }
    if ([val isKindOfClass:[NSAttributedString class]]) {
        return [NSString stringWithFormat:@"NSAttributedString len=%lu",
                (unsigned long)[(NSAttributedString *)val length]];
    }
    if ([val isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"NSArray count=%lu", (unsigned long)[(NSArray *)val count]];
    }
    if ([val isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"NSDictionary count=%lu", (unsigned long)[(NSDictionary *)val count]];
    }
    if ([val isKindOfClass:[NSNumber class]]) {
        return [NSString stringWithFormat:@"NSNumber %@", [(NSNumber *)val stringValue]];
    }
    if ([val isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)val;
        return [NSString stringWithFormat:@"UIView<%@> frame=%@ hidden=%d alpha=%.2f",
                LBForensicsSafeClassName(v),
                NSStringFromCGRect(v.frame), v.isHidden, v.alpha];
    }
    if ([val isKindOfClass:[UIViewController class]]) {
        return [NSString stringWithFormat:@"UIViewController<%@>", LBForensicsSafeClassName(val)];
    }
    return LBForensicsSafeClassName(val);
}

static BOOL LBForensicsIvarIsObjectPointer(Ivar iv) {
    const char *t = ivar_getTypeEncoding(iv);
    if (!t || !t[0]) return NO;
    return t[0] == '@' || t[0] == '#';
}

static id LBForensicsSafeObjectIvar(id obj, Ivar iv) {
    if (!obj || !iv || !LBForensicsIvarIsObjectPointer(iv)) return nil;
    @try {
        return object_getIvar(obj, iv);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *LBForensicsDescribeIvarValue(id model, Ivar iv) {
    if (!LBForensicsIvarIsObjectPointer(iv)) {
        const char *itype = ivar_getTypeEncoding(iv);
        return [NSString stringWithFormat:@"scalar:%s", itype ? itype : "?"];
    }
    @try {
        id val = LBForensicsSafeObjectIvar(model, iv);
        if (!val) return @"null";
        return LBForensicsDescribeValueShape(val);
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"err:%@", ex.reason ?: @""];
    }
}

static BOOL LBForensicsObjectIsCTFrameLike(id val) {
    if (!val) return NO;
    NSString *cn = LBForensicsSafeClassName(val);
    if ([cn containsString:@"CTFrame"] || [cn isEqualToString:@"__NSCFType"]) {
        @try {
            if ([val respondsToSelector:@selector(string)]) {
                NSString *s = [val performSelector:@selector(string)];
                if ([s containsString:@"CTFrame"]) return YES;
            }
        } @catch (__unused NSException *e) {}
    }
    return [cn containsString:@"CTFrame"];
}

static NSDictionary *LBForensicsDescribeCTFrameIvar(id model, Ivar iv) {
    if (!LBForensicsIvarIsObjectPointer(iv)) return @{@"exists": @NO};
    @try {
        id val = LBForensicsSafeObjectIvar(model, iv);
        if (!val) return @{@"exists": @NO};
        if (LBForensicsObjectIsCTFrameLike(val)) {
            NSUInteger textLen = 0;
            @try {
                if ([model respondsToSelector:@selector(attributedText)]) {
                    NSAttributedString *a = [model valueForKey:@"attributedText"];
                    if ([a isKindOfClass:[NSAttributedString class]]) textLen = a.length;
                }
                if (textLen == 0 && [model respondsToSelector:@selector(text)]) {
                    NSString *t = [model valueForKey:@"text"];
                    if ([t isKindOfClass:[NSString class]]) textLen = t.length;
                }
            } @catch (__unused NSException *e) {}
            return @{@"exists": @YES, @"textLen": @(textLen)};
        }
        const char *itype = ivar_getTypeEncoding(iv);
        if (itype && strstr(itype, "CTFrame")) {
            return @{@"exists": @YES, @"textLen": @0};
        }
    } @catch (__unused NSException *e) {}
    return @{@"exists": @NO};
}

NSArray<NSString *> *LBForensicsCandidateClassNames(void) {
    return @[
        @"TextReadVC3",
        @"TextRPageContainer",
        @"TextRPageContainerPage",
        @"TextRScrollContainer",
        @"TextReadTV",
        @"ReadPageModel",
    ];
}

NSDictionary *LBForensicsDumpIvars(id obj) {
    if (!obj) return @{};
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableDictionary *ctSummary = [NSMutableDictionary dictionary];
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count; i++) {
                const char *iname = ivar_getName(ivars[i]);
                const char *itype = ivar_getTypeEncoding(ivars[i]);
                if (!iname) continue;
                NSString *name = [NSString stringWithUTF8String:iname];
                NSString *typeEnc = itype ? [NSString stringWithUTF8String:itype] : @"?";
                NSString *valueSummary = @"?";
                NSDictionary *ctInfo = nil;
                @try {
                    if (LBForensicsIvarIsObjectPointer(ivars[i])) {
                        valueSummary = LBForensicsDescribeIvarValue(obj, ivars[i]);
                        if ([name.lowercaseString containsString:@"ctframe"] ||
                            (itype && strstr(itype, "CTFrame"))) {
                            ctInfo = LBForensicsDescribeCTFrameIvar(obj, ivars[i]);
                        }
                    } else {
                        valueSummary = [NSString stringWithFormat:@"scalar:%s", typeEnc.UTF8String];
                    }
                } @catch (NSException *ex) {
                    valueSummary = [NSString stringWithFormat:@"err:%@", ex.reason ?: @""];
                }
                NSMutableDictionary *row = [@{
                    @"name": name,
                    @"typeEncoding": typeEnc,
                    @"declaringClass": NSStringFromClass(cls),
                    @"valueSummary": valueSummary,
                } mutableCopy];
                if (ctInfo) {
                    row[@"ctFrame"] = ctInfo;
                    if ([ctInfo[@"exists"] boolValue]) {
                        ctSummary[name] = ctInfo;
                    }
                }
                [rows addObject:row];
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
    }
    return @{@"ivars": rows, @"ctFrameFields": ctSummary};
}

NSDictionary *LBForensicsDumpObjectRelations(id obj) {
    NSMutableDictionary *rel = [NSMutableDictionary dictionary];
    rel[@"address"] = LBForensicsPointer(obj);
    rel[@"class"] = LBForensicsSafeClassName(obj);
    Class sup = class_getSuperclass(object_getClass(obj));
    rel[@"superclass"] = sup ? NSStringFromClass(sup) : @"-";

    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        rel[@"kind"] = @"UIView";
        rel[@"frame"] = NSStringFromCGRect(v.frame);
        rel[@"bounds"] = NSStringFromCGRect(v.bounds);
        rel[@"hidden"] = @(v.isHidden);
        rel[@"alpha"] = @(v.alpha);
        rel[@"superview"] = v.superview ? @{
            @"address": LBForensicsPointer(v.superview),
            @"class": LBForensicsSafeClassName(v.superview),
        } : [NSNull null];
        NSMutableArray *subs = [NSMutableArray array];
        for (UIView *s in v.subviews) {
            [subs addObject:@{@"address": LBForensicsPointer(s), @"class": LBForensicsSafeClassName(s)}];
        }
        rel[@"subviews"] = subs;
        if (v.nextResponder && v.nextResponder != v) {
            rel[@"nextResponder"] = @{
                @"address": LBForensicsPointer(v.nextResponder),
                @"class": LBForensicsSafeClassName(v.nextResponder),
            };
        }
    } else if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        rel[@"kind"] = @"UIViewController";
        rel[@"viewLoaded"] = @(vc.isViewLoaded);
        if (vc.parentViewController) {
            rel[@"parentViewController"] = @{
                @"address": LBForensicsPointer(vc.parentViewController),
                @"class": LBForensicsSafeClassName(vc.parentViewController),
            };
        }
        NSMutableArray *children = [NSMutableArray array];
        for (UIViewController *ch in vc.childViewControllers) {
            [children addObject:@{@"address": LBForensicsPointer(ch), @"class": LBForensicsSafeClassName(ch)}];
        }
        rel[@"childViewControllers"] = children;
        if (vc.presentingViewController) {
            rel[@"presentingViewController"] = @{
                @"address": LBForensicsPointer(vc.presentingViewController),
                @"class": LBForensicsSafeClassName(vc.presentingViewController),
            };
        }
        if (vc.presentedViewController) {
            rel[@"presentedViewController"] = @{
                @"address": LBForensicsPointer(vc.presentedViewController),
                @"class": LBForensicsSafeClassName(vc.presentedViewController),
            };
        }
    } else {
        rel[@"kind"] = @"NSObject";
    }

    NSMutableArray *held = [NSMutableArray array];
    NSDictionary *ivarDump = LBForensicsDumpIvars(obj);
    for (NSDictionary *row in ivarDump[@"ivars"]) {
        NSString *vs = row[@"valueSummary"];
        if ([vs isEqualToString:@"null"] || [vs hasPrefix:@"err:"]) continue;
        if ([vs hasPrefix:@"UIView"] || [vs hasPrefix:@"UIViewController"] ||
            [vs hasPrefix:@"NSArray"] || [vs hasPrefix:@"NSDictionary"] ||
            [vs hasPrefix:@"NSString"] || [vs hasPrefix:@"NSAttributedString"] ||
            ([vs containsString:@"Read"] && ![vs isEqualToString:@"?"])) {
            [held addObject:@{@"ivar": row[@"name"], @"summary": vs}];
        }
    }
    rel[@"heldReferences"] = held;
    return rel;
}

NSDictionary *LBForensicsWriteDumpFiles(NSDictionary *dump) {
    NSString *sha = dump[@"manifest_sha_prefix"] ?: @"unknown";
    NSString *phase = dump[@"phase"] ?: @"manual";
    NSString *stamp = LBForensicsFileStamp();
    NSString *base = [NSString stringWithFormat:@"forensics_dump_%@_%@_%@", sha, phase, stamp];
    NSString *jsonName = [base stringByAppendingString:@".json"];
    NSString *txtName = [base stringByAppendingString:@".txt"];
    NSString *legacyName = @"legado_debug_dump.txt";

    NSString *docs = LBForensicsDocumentsDir();
    NSString *jsonPath = [docs stringByAppendingPathComponent:jsonName];
    NSString *txtPath = [docs stringByAppendingPathComponent:txtName];
    NSString *legacyPath = [docs stringByAppendingPathComponent:legacyName];

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dump options:NSJSONWritingPrettyPrinted error:nil];
    if (jsonData) {
        [jsonData writeToFile:jsonPath atomically:YES];
    }

    NSString *text = dump[@"textSummary"] ?: @"";
    [text writeToFile:txtPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [text writeToFile:legacyPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    return @{
        @"json": jsonPath,
        @"text": txtPath,
        @"legacy": legacyPath,
        @"basename": base,
    };
}

// 供其他模块使用
NSString *LBForensicsUTCNowString(void) { return LBForensicsUTCNow(); }
NSString *LBForensicsManifestSHAPrefix(void) { return LBForensicsManifestSHA(); }
NSString *LBForensicsDocumentsDirectory(void) { return LBForensicsDocumentsDir(); }
