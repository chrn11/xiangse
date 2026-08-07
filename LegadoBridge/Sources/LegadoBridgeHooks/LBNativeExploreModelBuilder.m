#import "LBNativeExploreModelBuilder.h"

NSString * const LBNativeExploreAdapterSchema = @"lb.discover.adapter.v1";
NSString * const LBNativeExploreAdapterMarkerKey = @"_lb_adapter";
NSString * const LBNativeExploreStructureActionID = @"bookWorld";
NSString * const LBNativeExploreStructureParserID = @"__lb_struct_parser__";

static NSError *LBNativeExploreError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"LBNativeExploreModelBuilder"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

@implementation LBNativeExploreModelBuilder

+ (NSDictionary *)adapterModelFromMetadataJSON:(NSData *)jsonData
                                         error:(NSError *_Nullable *_Nullable)error {
    if (jsonData.length == 0) {
        if (error) *error = LBNativeExploreError(1, @"empty metadata");
        return @{};
    }
    id obj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (error && !*error) *error = LBNativeExploreError(2, @"metadata root not object");
        return @{};
    }
    NSDictionary *meta = (NSDictionary *)obj;

    // 拒绝敏感/可执行字段渗入
    static NSArray<NSString *> *forbiddenKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        forbiddenKeys = @[
            @"requestInfo", @"list", @"requestFilters", @"parser", @"Cookie", @"cookie",
            @"token", @"Authorization", @"rawTarget", @"sourceUrl", @"bookSourceUrl"
        ];
    });
    for (NSString *k in forbiddenKeys) {
        if (meta[k] != nil) {
            if (error) *error = LBNativeExploreError(3, [NSString stringWithFormat:@"forbidden key %@", k]);
            return @{};
        }
    }

    NSString *snapshotID = [meta[@"snapshotID"] isKindOfClass:[NSString class]] ? meta[@"snapshotID"] : @"";
    NSString *sourceHash = [meta[@"sourceIdentityHash"] isKindOfClass:[NSString class]] ? meta[@"sourceIdentityHash"] : @"";
    NSString *state = [meta[@"state"] isKindOfClass:[NSString class]] ? meta[@"state"] : @"ready";
    NSNumber *schemaVer = [meta[@"schemaVersion"] isKindOfClass:[NSNumber class]] ? meta[@"schemaVersion"] : @1;
    NSArray *channelsIn = [meta[@"channels"] isKindOfClass:[NSArray class]] ? meta[@"channels"] : @[];

    NSMutableArray *channelsOut = [NSMutableArray arrayWithCapacity:channelsIn.count];
    for (id chObj in channelsIn) {
        if (![chObj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *ch = (NSDictionary *)chObj;
        NSString *channelID = [ch[@"channelID"] isKindOfClass:[NSString class]] ? ch[@"channelID"] : @"";
        NSString *title = [ch[@"title"] isKindOfClass:[NSString class]] ? ch[@"title"] : @"";
        NSArray *nodesIn = [ch[@"nodes"] isKindOfClass:[NSArray class]] ? ch[@"nodes"] : @[];
        NSMutableArray *nodesOut = [NSMutableArray arrayWithCapacity:nodesIn.count];
        NSMutableArray *tagTitles = [NSMutableArray array];
        NSMutableArray *tagNodeIDs = [NSMutableArray array];
        for (id nObj in nodesIn) {
            if (![nObj isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *n = (NSDictionary *)nObj;
            // 再拒 raw target
            if (n[@"rawTarget"] != nil || n[@"url"] != nil || n[@"requestInfo"] != nil) {
                if (error) *error = LBNativeExploreError(4, @"node carries raw target/url/requestInfo");
                return @{};
            }
            NSString *nodeID = [n[@"nodeID"] isKindOfClass:[NSString class]] ? n[@"nodeID"] : @"";
            NSString *ntitle = [n[@"title"] isKindOfClass:[NSString class]] ? n[@"title"] : @"";
            NSString *kind = [n[@"kind"] isKindOfClass:[NSString class]] ? n[@"kind"] : @"unsupported";
            BOOL selectable = [n[@"selectable"] respondsToSelector:@selector(boolValue)] ? [n[@"selectable"] boolValue] : NO;
            NSDictionary *node = @{
                @"nodeID": nodeID ?: @"",
                @"title": ntitle ?: @"",
                @"kind": kind ?: @"unsupported",
                @"selectable": @(selectable),
            };
            [nodesOut addObject:node];
            if (selectable && nodeID.length > 0) {
                [tagTitles addObject:ntitle ?: @""];
                [tagNodeIDs addObject:nodeID];
            }
        }
        NSMutableDictionary *chOut = [NSMutableDictionary dictionary];
        chOut[@"channelID"] = channelID ?: @"";
        chOut[@"title"] = title ?: @"";
        chOut[@"nodes"] = [nodesOut copy];
        chOut[@"tagTitles"] = [tagTitles copy];
        chOut[@"tagNodeIDs"] = [tagNodeIDs copy]; // requestFilters value 只放 nodeID
        if ([ch[@"styleHints"] isKindOfClass:[NSDictionary class]]) {
            chOut[@"styleHints"] = ch[@"styleHints"];
        }
        [channelsOut addObject:chOut];
    }

    NSDictionary *model = @{
        LBNativeExploreAdapterMarkerKey: @1,
        @"schema": LBNativeExploreAdapterSchema,
        @"schemaVersion": schemaVer,
        @"sourceIdentityHash": sourceHash ?: @"",
        @"snapshotID": snapshotID ?: @"",
        @"state": state ?: @"ready",
        @"channels": [channelsOut copy],
        // 结构常量：仅供创建原生 controller 形状，不含可执行规则
        @"actionID": LBNativeExploreStructureActionID,
        @"parserID": LBNativeExploreStructureParserID,
    };

    NSError *verr = nil;
    if (![self validateAdapterModel:model error:&verr]) {
        if (error) *error = verr;
        return @{};
    }
    return model;
}

+ (NSArray<NSString *> *)tagTitlesFromChannel:(NSDictionary *)channel {
    id v = channel[@"tagTitles"];
    return [v isKindOfClass:[NSArray class]] ? (NSArray *)v : @[];
}

+ (NSArray<NSString *> *)tagNodeIDsFromChannel:(NSDictionary *)channel {
    id v = channel[@"tagNodeIDs"];
    return [v isKindOfClass:[NSArray class]] ? (NSArray *)v : @[];
}

+ (BOOL)validateAdapterModel:(NSDictionary *)model
                       error:(NSError *_Nullable *_Nullable)error {
    if (![model[LBNativeExploreAdapterMarkerKey] respondsToSelector:@selector(boolValue)] ||
        ![model[LBNativeExploreAdapterMarkerKey] boolValue]) {
        if (error) *error = LBNativeExploreError(10, @"missing _lb_adapter");
        return NO;
    }
    if (![model[@"schema"] isEqual:LBNativeExploreAdapterSchema]) {
        if (error) *error = LBNativeExploreError(11, @"bad schema");
        return NO;
    }
    if (![(model[@"snapshotID"] ?: @"") isKindOfClass:[NSString class]] ||
        [model[@"snapshotID"] length] == 0) {
        if (error) *error = LBNativeExploreError(12, @"missing snapshotID");
        return NO;
    }
    if (![(model[@"sourceIdentityHash"] ?: @"") isKindOfClass:[NSString class]] ||
        [model[@"sourceIdentityHash"] length] == 0) {
        if (error) *error = LBNativeExploreError(13, @"missing sourceIdentityHash");
        return NO;
    }
    // 禁止可执行载荷
    for (NSString *k in @[@"requestInfo", @"list", @"requestFilters", @"Cookie", @"cookie", @"token"]) {
        if (model[k] != nil) {
            if (error) *error = LBNativeExploreError(14, [NSString stringWithFormat:@"forbidden %@", k]);
            return NO;
        }
    }
    return YES;
}

@end
