# 核心数据流图解

> 对照当前 `aux_v2.lua`。重点是输入解析、引导键防吞噬、普通辅码筛选、分心、断句和修音。

## 1. 主入口

```text
用户按键
  ↓
Rime 调用 lua_filter
  ↓
AuxFilter.func(input, env)
  ↓
初始化/清理当前轮 S 状态
  ↓
AuxFilter.Update_codes(ctx)
  ↓
输入形态分发
```

分发顺序：

```text
只有引导键
  → return，不产出候选

拼音;辅码
  → main1()

拼音;辅码`
  → switch_single_char() → main1()

拼音;辅码;功能
  → longcandimodify()

其他
  → defaultmain()
```

## 2. 输入解析与防吞噬

当前修复的核心在 `Update_codes()`：

```text
context.input
  ↓ transform_input_code()
S.inputCode
  ↓ split_first_plain(input, trigger)
S.removeAuxInput = 第一个引导键前的输入
S.raw_tail       = 第一个引导键后的尾部
S.has_trigger   = 是否包含引导键
```

preedit 同步处理：

```text
context:get_preedit().text
  ↓ transform_input_code()
S.precode
  ↓ split_first_plain(preedit, trigger)

preedit 仍含引导键：
  S.removeAuxprecode = preedit_prefix
  preedit_prefix_cache[input_prefix] = preedit_prefix

preedit 不含引导键：
  S.removeAuxprecode =
    preedit_prefix_cache[input_prefix]
    或 strip_ascii_tail_leak(preedit_prefix, raw_tail)
```

这解决了最近的引导键吞噬问题：Rime 有时会让 `context.input` 和 `preedit` 对引导键的表现不同，旧逻辑只看一边，选中后容易恢复错输入。

## 3. 普通辅码筛选

```text
输入: cai;p

S.raw_tail = "p"
  ↓
main1.process_input()
  → S.auxStr = "p"
  → S.funccode = ""
  ↓
遍历候选
  ↓
main_main(env, cand)
  ↓
候选文本查辅码
  ├─ 单字: fullAux_precomputed
  └─ 多字: fullAuxCache 或 fullAux()
  ↓
AuxFilter.match(fullAuxCodes, S.auxStr)
  ↓
命中则 yield_candisub()
```

候选输出前还会处理：

- 辅码注释。
- 去重。
- `w` 跳过首候选。
- `c/v/b/n` 复制。
- `t` 简繁转换或外部接口转换。
- `rXX` 把原始输入发给外部接口。

## 4. 二字词分心

二字词双码先检查首字：

```text
候选 = "心仪"
S.auxStr = "jb"

首字 "心" 是否可由 j 命中
  ├─ 否 → 拦截
  └─ 是 → 继续检查第二字

第二字 "仪" 是否可由 b 命中
  ├─ 是，普通双码 → 输出 ** 标记
  ├─ 是，主动分心 → 输出 ⇐ 标记
  └─ 否，但首字已锁定 → 进入潜在分心
```

潜在分心会做前瞻探路：

```text
取第二个音节
  ↓
get_syllable_aux_set(第二音节)
  ↓
combmath(第二码, 音节辅码集合)
  ├─ 命中 → 保留 *x / ✂ 候选
  └─ 不命中 → 拦截，避免误导
```

主动分心由占位符触发，例如 `xinyi;hj,`。

## 5. 长句断句

```text
输入: wodewuliiglewodebdbi;du;

S.raw_tail = "du;"
  ↓
parse_long_tail(raw_tail, ";")
  → auxcode = "du"
  → funccode = ""
  ↓
取首候选和 preedit 音节数组
  ↓
find_break_point(inputspls, "du")
  ↓
逐音节查询 get_syllable_aux_set()
  ↓
combmath("du", fuset)
  ↓
命中后设置 S.ficompensate
  ↓
yield 截断候选
```

连续多个引导键会增加跳过次数，用于定位后续命中点。

## 6. 修音

```text
输入: zvjxgruz;wk;sge

parse_long_tail()
  → auxcode = "wk"
  → funccode = "sge"
  → ybmodif = "ge"
  ↓
find_break_point() 定位错音节附近
  ↓
branchmark = 2
  ↓
复制 inputspls 到 fresh_spls
  ↓
检查 target_idx 是否越界
  ↓
fresh_spls[target_idx] = "ge"
  ↓
S.ybmodifiedcode = S.transdcodei .. table.concat(fresh_spls) .. trigger
  ↓
选中提示候选后 longcandimodify_ybnotifier() 重写 ctx.input
```

这里不能直接改 `inputspls`，因为它可能来自 `split_pinyin()` 缓存。

## 7. 选中后的输入恢复

```text
select_notifier
  ↓
S.notifiermark
  ├─ 1: main1_notifier()
  ├─ 2: longcandimodify_notifier()
  └─ 3: longcandimodify_ybnotifier()
```

普通辅码：

```text
有已转换输入 → ctx.input = removeAuxInput .. trigger .. aux_left
否则         → ctx.input = removeAuxInput
```

长句断句：

```text
有已转换输入 → ctx.input = removeAuxInput .. trigger .. auxcode
否则         → ctx.input = removeAuxInput
```

修音：

```text
ctx.input = S.ybmodifiedcode
```

## 8. 缓存和生命周期

| 缓存 | 生命周期 | 用途 |
|---|---|---|
| `AuxFilter.aux_code` | 进程级 | 字到辅码表 |
| `AuxFilter.fullAux_precomputed` | 进程级 | 单字辅码 O(1) 查询 |
| `fullAuxCache` | 进程级 | 多字词辅码按需缓存 |
| `pinyin_cache` | 进程级 | preedit 空格切分结果 |
| `syllable_aux_cache` | 进程级 | 精确音节到辅码集合 |
| `preedit_prefix_cache` | composition 级 | 防止引导键吞噬时丢失 preedit 前缀 |
| `S.yieldset` / `S.yieldrawset` | 单轮 | 候选去重 |

composition 结束时，`update_notifier` 会清理单字模式、剩余辅码、转换结果和 `preedit_prefix_cache`。
