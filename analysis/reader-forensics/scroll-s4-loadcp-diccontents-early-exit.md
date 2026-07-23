# scroll-S4：禁止预种 dicContents（loadCp 早退）

## 反汇编（`ReadScrollContainer#loadCp:` @ `0x1000a3508`）

1. `numberWithInteger:` 得到 cp key  
2. `dicContents[key]`（ivar off=8）非空 → **早退**（`0x1000a35a0`）  
3. 否则 `dicQuerying[key]`（ivar off=40）非空 → **早退**  
4. 否则校验 `reader.arrCatalog.count`，再 `queryCpFileByBook:cpInfo:cpIndex:userInfo:target:cachePolicy:`

## S3 真机对照（`0626893`）

- `dicContents@c=4` + `scroll_S3b seed dicContents@TextRScrollContainer`  
- `invoke_loadCp` OK，但无 QF / `divisionResponse`  
- 预种正文正好命中步骤 2，把 query 链堵死

## 修复

- `LBSeedConfirmedCache`：滚动容器跳过 `LBApplyDicContents`（`dicContents@scroll_skip_S4`）  
- `LBEnsureLoadCurCpPrereqs`：清除滚动容器上该章的 `dicContents` / `dicQuerying` key；保留空 `dicHeight`；正文仍靠 xsfolder / `setCpCached`

预期 trace：`scroll_S4 prep paths=clear_dicContents_keys` → `invoke_loadCp` → 后续 QF / `divisionResponse`
