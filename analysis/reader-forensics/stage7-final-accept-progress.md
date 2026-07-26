# 阶段七总验收进度（2026-07-26）

用户已批准开工。当前包：`d78bc31` / run `30193066761` / `legado-debug`。

## 选源

| 角色 | 源 | 夹具 |
|---|---|---|
| 主 | 领域书库 `http://www.lysxh.com`（yckceo id/7548） | `fixtures/stage7/lingyu.json` → mock `http://192.168.1.4:8766/stage7/lingyu.json` |
| 对照 | 笔趣读 `https://www.biqudv.com`（yckceo id/5811） | `fixtures/stage7/biqudv.json`；**登录需真实账号，勿瞎填** |

## 矩阵

| ID | 项 | 状态 |
|---|---|---|
| L0 | 领域源冷启动闪退 | **PASS**（`1d4936f`：`lastUpdateTime` 持久化为 int；冷启 UI 书架） |
| L1 | 领域：导入 | **PASS**（`legado_import_fetch.txt`=`import ok count=1`；深链 `legado://import/bookSource?src=`） |
| L2 | 领域：搜索 | **PASS**（`ok total=50`；probe 含 `/html/79750/`） |
| L3 | 领域：目录 | **PASS**（`chapters=1914` first=第一章 陨落的天才；`@` 链 + `.-1`） |
| L4 | 领域：正文 | **FAIL**：种文件内容竟是 `replaceRegex` 模式串（`##pattern##` 前导解析反了 → 空正文被写成正则）；已修待复验 |
| L5 | 领域：发现 | 待 L4 后 |
| L6 | 领域：CF / browserAwait | 详情页探针 `cf=false`；loginCheckJs 已改 block 注入 |
| B1 | 笔趣读：导入 + 打开 loginUi | 待跑 |
| B2 | 笔趣读：真实账号登录→搜索→正文 | **阻塞：等用户提供账号** |
| R1 | Release IPA mock+起点冒烟 | 待跑 |
| P1 | Legado 原版对拍 | 最小登记 / 抽样 |

## 证据

- 导入+冷启：`fixtures/_devkit/stage7/lingyu_import_probe_20260726T042757Z.json`
- 搜索 50：`fixtures/_devkit/stage7/`（search probe 日志）
- 目录失败：`legado_catalog_last.txt` = SwiftSoup.Exception错误0；无 `legado_catalog_body_probe.txt`（崩在详情 parse 前）

## 进行中代码

- `SourceRegistry.sanitizeSourceJSON` + 去 `try!`（`8666566`/`1d4936f`）
- `RuleWebBook.applyLoginCheckIfNeeded`：注入带 `body()`/`url()` 的 `result`；写 `legado_bookinfo_body_probe.txt` / `legado_login_check_probe.txt`
