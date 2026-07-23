# tr_turnPageType 工厂分支纠偏（scroll-S1）

**日期**：2026-07-23  
**证据**：`pagecontainer-kill-analysis.md` 指令 `0x100066924–92c` + BC17 真机 `hypothesis_B2 seed=0` 仍得 `TextRPageContainer`

## 反汇编（ARM64）

```
cmp  x20, #3                 ; type ?= 3
ccmp w8, #0, #0, ne          ; type!=3 → 再比 bd8==0；type==3 → NZCV=#0（Z=0）
b.eq → TextRPageContainer    ; Z=1 才进分页
; fallthrough → TextRScrollContainer
```

## 真值表

| type | bd8 | Z / 分支 |
|------|-----|----------|
| 3 | * | Z=0 → **Scroll** |
| ≠3 | 0 | Z=1 → **Page** |
| ≠3 | ≠0 | Z=0 → **Scroll** |

## 证伪旧 B2 注释

旧注释「0=滚动、禁 3」与上表相反。BC17：`seed tr_turnPageType=0` + `bd8=0x00` → `container_first_seen=TextRPageContainer`（与表一致）。

## 改动

`LBSeedTurnPageTypeScrollBranch` 改为 `tr_turnPageType=3`，trace 标签 `scroll_S1`。
