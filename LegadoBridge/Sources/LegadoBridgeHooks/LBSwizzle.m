#import "LBInternal.h"
#import "LegadoBridge.h"

void LBShowLegadoImportAlert(void) {
    LBLegadoShowImportAlert();
}

void LBPresentLegadoSourceManager(NSString *sourceUrl) {
    LBLegadoPresentManagerVC(sourceUrl);
}

void LBInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LBCapabilityResetAll();
        // 顺序：先校验/探针，再导入/搜索/列表/阅读；任一组失败不阻断其余（fail-open）
        LBInstallRuntimeValidateHooks();
        LBInstallImportHooks();
        LBInstallOpenURLHook();
        LBInstallSearchHooks();
        LBInstallSourceListHooks();
        LBInstallReadingHooks();
        LBCapabilityPersistMarker();
        NSLog(@"[LegadoBridge] hooks installed, version=%@ diag=%d",
              LBBridgeVersion(), (int)LBDiagProbesEnabled());
    });
}

__attribute__((constructor))
static void LBBridgeAutoInit(void) {
    [@"dylib loaded" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_dylib_loaded.txt"]
                      atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    LBInstallHooks();
    [@"hooks installed" writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/legado_hooks_installed.txt"]
                         atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}
