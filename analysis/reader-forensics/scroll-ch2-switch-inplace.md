# 滚动切章：同书 idx 原地切换

## 现象

S5 `nativeRead idx=1` 报 PASS，但 `ch2.png` 为「第二章 斗气大陆 / 请求错误」；`attString` 仍是第一章；trace 大量 `nativeRead skip chapterDone sameBook`。

## 根因

1. `LBOpenNativeChapterAtIndex` 在 `sNativeOpenChapterDone && sameBook` 时直接 return，**不区分 idx**。验收脚本 `rm openOnce` 只清磁盘，内存 `chapterDone` 仍为 YES。
2. 门禁 `ch2_marker` 回退到 UI 标题「第二章」，错误页也能过。
3. 滚动预取下一章时 `dicQueryError` 有记录；`localSourceText` seed 只写当前章，覆盖 list。

## 修复

- 同书、阅读页在栈、`curIdx != wantIdx` → `LBSwitchNativeChapterInPlace`：更新 openOnce key、重置 loadCurCp 状态机、`LBHandleContentRequest` → 既有 `OnContentPosted` → seed xsfolder → `loadCp:`。
- 同 idx 仍 skip（防双 push），**且不再 deliver/overlay**（曾叠字）。
- 切章时滚动容器清空 `dicContents`/`dicHeight`/`dicQueryError`/`arrCpIndex` 并 `scrollToTop`。
- `dicQueryError` 随 S4 prep 清 key；`localSourceText.list` 合并不覆盖。
- S5 门禁：正文必含「斗气大陆」或「纳兰嫣然」，且 UI 无「请求错误」。
