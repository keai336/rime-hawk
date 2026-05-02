# API 速查手册

> 对照当前 `aux_v2.lua`。`aux_v2_debug.lua` 保持同一逻辑，只额外输出结构化调试日志。

## Rime Filter 接口

### `AuxFilter.init(env)`

初始化运行时配置和资源。

| 项 | 当前行为 |
|---|---|
| 配置格式 | `path@showor@trigger@switch@ph@matchmode` |
| 默认值 | `` ZRM_Aux-code@on@;@`@,@s `` |
| preedit | 读取 `translator/preedit_format1` 并创建 `Projection` |
| 辅码表 | 首次加载 `path.txt` 到 `AuxFilter.aux_code` |
| Memory | 绑定 translator，用于断句、修音、音节辅码探路 |
| 通知器 | 连接 `update_notifier` 和 `select_notifier` |

### `AuxFilter.func(input, env)`

每轮候选刷新入口。当前分支先执行 `Update_codes(ctx)`，再按输入形态分支：

| 条件 | 分支 | 说明 |
|---|---|---|
| 只有引导键 | 直接返回 | 防止 `;` 独立成段时透传无关候选 |
| `pattern_main1` | `main1()` | 普通辅码筛选 |
| `pattern_singlechar_switch` | `switch_single_char()` + `main1()` | 切换单字筛选 |
| `pattern_long` | `longcandimodify()` | 长句断句 / 修音 |
| 其他 | `defaultmain()` | 透传候选 |

### `AuxFilter.fini(env)`

断开通知器。调试版不会在这里关闭模块级日志文件，避免 Rime 生命周期内重复 close。

## 输入解析接口

### `AuxFilter.Update_codes(ctx)`

把 Rime 上下文整理为后续分支使用的状态。

| 字段 | 来源 / 含义 |
|---|---|
| `S.inputCode` | `context.input`，经过 `transform_input_code()` |
| `S.precode` | `context:get_preedit().text`，经过 `transform_input_code()` |
| `S.has_trigger` | input 是否包含第一个引导键 |
| `S.raw_tail` | 第一个引导键之后的原始尾部 |
| `S.removeAuxInput` | 第一个引导键之前的输入前缀 |
| `S.preedit_has_trigger` | preedit 是否仍包含引导键 |
| `S.removeAuxprecode` | preedit 前缀；优先直接拆分，其次读 `preedit_prefix_cache`，最后用 `strip_ascii_tail_leak()` 兜底 |
| `S.transdcode` / `S.transdcodei` | 去掉已转换输入片段后的 preedit/input 前缀 |

### `split_first_plain(str, sep)`

按第一个普通分隔符拆分，不使用 Lua pattern。用于避免自定义引导键被 pattern 语义影响。

返回：`prefix, tail, has_sep`。

### `strip_ascii_tail_leak(preedit, tail)`

当 input 已有引导键、preedit 却不含引导键时，移除 preedit 尾部疑似泄漏的 ASCII 辅码尾巴。

### `parse_long_tail(tail, trigger)`

解析长句尾部。输入是 `S.raw_tail`，不是完整 input。

```text
du;      -> auxcode=du, funccode=""
du;sge   -> auxcode=du, funccode=sge
du;;a    -> auxcode=du, funccode=a
```

### `transform_input_code(inputcode)`

把使用占位符触发的输入规整为内部可处理形式。使用 `init()` 阶段预编译的 `pattern_transform` / `repl_transform`。

## 辅码匹配接口

### `AuxFilter.readAuxTxt(txtpath)`

读取 `<txtpath>.txt`。

| 输出 | 说明 |
|---|---|
| `AuxFilter.aux_code` | `字 -> "code1,code2"` |
| `AuxFilter.fullAux_precomputed` | 单字的 `{首码串, 次码串}` 预计算表 |

### `AuxFilter.fullAux(env, word)`

计算一个字或词的辅码串。单字优先使用 `fullAux_precomputed`；多字词结果由 `fullAuxCache` 按需缓存。

### `AuxFilter.match(fullAux, auxStr)`

判断普通辅码是否匹配。

| 模式 | 行为 |
|---|---|
| `matchmode=s` | 严格顺序，主要看首码串和完整双码 |
| `matchmode=m` | 全码兼容，允许更多次码/反向组合 |

### `get_syllable_aux_set(syllable)`

通过 `Memory:dict_lookup()` 查询某个音节可能对应的单字辅码集合。

| 缓存策略 | 当前行为 |
|---|---|
| 精确匹配成功 | 写入 `syllable_aux_cache` |
| 精确匹配失败且确认无结果 | 写入 `false`，避免重复扫描 |
| 前缀匹配 fallback | 不写长期缓存，因为结果受上下文影响 |

### `combmath(aux, fuset)`

判断断句/修音探路中的辅码是否命中音节辅码集合。`matchmode=m` 时额外允许反向双码。

## 处理分支

### `AuxFilter.main1(input, env)`

普通辅码筛选。

- 从 `S.raw_tail` 解析最多两位辅码和后续功能码。
- 逗号占位符触发主动分心。
- 候选由 `main_main(env, cand)` 检查辅码，再经 `yield_candisub()` 输出。
- 没有候选命中时，`handle_no_match()` 会给出可继续输入的截断候选。

### `main_main(env, cand)`

普通候选的核心匹配逻辑。

- 单字查 `fullAux_precomputed`。
- 多字词查 `fullAuxCache`，未命中则调用 `fullAux()`。
- 二字词双码支持普通命中、被动分心 `**`、潜在分心 `*x` 和主动分心 `⇐` / `✂`。
- 潜在分心会用第二音节做前瞻探路，失败则不输出误导候选。

### `AuxFilter.longcandimodify(input, env)`

长句断句与修音。

- `parse_long_tail()` 解析辅码和功能码。
- `find_break_point()` 用音节辅码集合定位断点。
- 普通断句输出断点前缀。
- 修音分支复制 `inputspls` 到 `fresh_spls` 后替换目标音节，避免污染 `split_pinyin()` 缓存。

### `AuxFilter.defaultmain(input, env)`

不符合辅码模式时透传候选，但仍通过 `yield_candisub()` 做候选包装和去重。

## 通知器回调

| `S.notifiermark` | 回调 | 作用 |
|---:|---|---|
| `1` | `main1_notifier(ctx)` | 普通辅码候选选中后提交前缀或恢复剩余辅码 |
| `2` | `longcandimodify_notifier(ctx)` | 断句选中后提交已截断文本或恢复长句尾部 |
| `3` | `longcandimodify_ybnotifier(ctx)` | 修音选中后把 `ctx.input` 改为重组后的输入码 |

`update_notifier` 在 composition 结束时清理单字模式、剩余辅码、转换结果和 `preedit_prefix_cache`。

## 常用状态字段

| 字段 | 说明 |
|---|---|
| `S.auxStr` | 当前轮辅码，最多两位 |
| `S.funccode` | 辅码后的功能指令 |
| `S.distraction` | 主动分心标记 |
| `S.aux_left` | 留给下一轮的剩余辅码 |
| `S.one_aux_firstcode` | 双码/分心时锁定的首字 |
| `S.last_fist_commit` | 最近首候选记录，用于避免重复首候选 |
| `S.ficompensate` | 长句断句/修音断点 |
| `S.ybmodifiedcode` | 修音后重组的输入码 |
| `S.yieldset` / `S.yieldrawset` | 当前轮候选去重集合 |
