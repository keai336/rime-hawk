# Rime Hawk 技术文档

> 当前实现：`aux_v2.lua` 为生产脚本，`aux_v2_debug.lua` 为同逻辑调试脚本。本文档按 2026-05-02 当前分支更新。

## 1. 定位

Rime Hawk 是一个 Rime Lua 过滤器。它不负责拼音翻译，而是在候选列表生成之后，用“拼音 + 辅码”继续筛选候选。

适合的能力边界：

- 高频路径：普通单码/双码辅码过滤。
- 低频纠偏：单字模式、二字词分心、长句断句、修音。
- 可选能力：简繁转换、本地 HTTP 请求。

## 2. 文件角色

| 文件 | 角色 |
|---|---|
| `aux_v2.lua` | 推荐部署的生产脚本 |
| `aux_v2_debug.lua` | 调试脚本，增加 JSONL 日志和触发源染色 |
| `test5.txt` | 示例辅码表 |
| `docs/log_parser.html` | 调试日志查看器 |

生产和调试脚本的业务逻辑应保持一致；调试版只增加日志，不作为默认部署目标。

## 3. 配置入口

```yaml
engine:
  filters:
    - lua_filter@aux_v2@test5@on@;@`@,@s
```

参数顺序：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `path` | `ZRM_Aux-code` | 辅码表文件名，不带 `.txt` |
| `showor` | `on` | 是否在候选注释中显示辅码 |
| `trigger` | `;` | 辅码引导键 |
| `switch` | `` ` `` | 单字模式切换键 |
| `ph` | `,` | 占位符，用于主动分心 |
| `matchmode` | `s` | `s` 为严格顺序，其他值走全码兼容 |

如果方案已有 `translator/preedit_format`，应改名为 `translator/preedit_format1`，让 Hawk 内部读取并应用 projection。

## 4. 入口架构

```text
AuxFilter.init(env)
  ├─ 解析 name_space 参数
  ├─ 加载 preedit_format1
  ├─ 加载辅码表并预计算单字 fullAux
  ├─ 初始化 OpenCC / Memory
  ├─ 预编译输入 pattern
  └─ 连接 update_notifier / select_notifier

AuxFilter.func(input, env)
  ├─ 清理当前轮状态
  ├─ Update_codes(ctx)
  ├─ 触发键独立成段守卫
  ├─ main1()
  ├─ switch_single_char() + main1()
  ├─ longcandimodify()
  └─ defaultmain()

AuxFilter.fini(env)
  └─ 断开通知器
```

## 5. 状态和缓存

### 5.1 当前轮状态 `AuxFilter.state`

| 字段 | 说明 |
|---|---|
| `inputCode` / `precode` | 当前 input 和 preedit，已做内部规整 |
| `has_trigger` / `preedit_has_trigger` | input/preedit 是否包含引导键 |
| `removeAuxInput` | 第一个引导键前的输入前缀 |
| `raw_tail` | 第一个引导键后的原始尾部 |
| `removeAuxprecode` | 去除辅码后的 preedit 前缀 |
| `removetransdInput` | preedit 中已被 projection 转换的输入片段 |
| `transdcode` / `transdcodei` | 去除转换片段后的前缀 |
| `auxStr` / `funccode` | 当前辅码和功能指令 |
| `single_flag` | 单字筛选模式 |
| `distraction` | 主动分心模式 |
| `aux_left` | 留给下一轮的剩余辅码 |
| `ficompensate` | 长句断句/修音断点 |
| `ybmodifiedcode` | 修音后重组输入 |

### 5.2 进程级缓存

| 缓存 | 说明 |
|---|---|
| `AuxFilter.aux_code` | 字到辅码字符串 |
| `AuxFilter.fullAux_precomputed` | 单字 `{首码串, 次码串}` |
| `fullAuxCache` | 多字候选 fullAux 按需缓存 |
| `pinyin_cache` | preedit 音节切分缓存 |
| `syllable_aux_cache` | 精确音节到辅码集合 |
| `preedit_prefix_cache` | composition 内 preedit 前缀缓存，用于防吞噬 |

## 6. 输入解析和引导键防吞噬

最近修复的核心在 `Update_codes(ctx)`。

旧问题是：Rime 有时会让 `context.input` 保留引导键，但 `preedit` 不保留，或把辅码尾巴混入 preedit。选中候选后如果只信任其中一边，就会出现引导键被吞、尾部重复或剩余输入错误。

当前流程：

1. `context.input` 和 `preedit` 都先经过 `transform_input_code()`。
2. 用 `split_first_plain()` 按第一个引导键拆分 input，得到 `removeAuxInput` 和 `raw_tail`。
3. 同样拆分 preedit。
4. 如果 preedit 仍含引导键，直接记录 preedit 前缀，并写入 `preedit_prefix_cache[input_prefix]`。
5. 如果 preedit 不含引导键，优先从缓存恢复；没有缓存时，用 `strip_ascii_tail_leak()` 去掉可能泄漏的 ASCII 尾巴。
6. 输入只有引导键时，`func()` 直接返回，不再透传候选。

这使普通辅码、分心、断句和修音都共享同一套前缀恢复逻辑。

## 7. 普通辅码筛选

`main1()` 解析 `S.raw_tail`：

- 前两位作为辅码候选。
- 占位符 `,` 会被剥离。
- 两位辅码后紧跟占位符时，进入主动分心。
- 剩余部分交给 `parseIntelligentCode()` 解析。

`main_main()` 负责候选匹配：

1. 取候选真实文本，Shadow 候选取 genuine text。
2. 单字优先查 `fullAux_precomputed`。
3. 多字词查 `fullAuxCache`，未命中再调用 `fullAux()`。
4. 调用 `AuxFilter.match()` 判断普通辅码。
5. 二字词双码进入分心逻辑。
6. 命中候选通过 `yield_candisub()` 输出。

没有候选命中时，`handle_no_match()` 用首候选生成可继续输入的截断候选。当前实现已修正兜底候选 `_start/_end` 范围。

## 8. 分心机制

分心是低频纠偏，不是普通输入主路径。

| 标记 | 来源 | 含义 |
|---|---|---|
| `**` | 被动分心 | 二字词两字分别命中双码 |
| `*x` | 潜在分心 | 首字命中，次码保留给下一轮 |
| `⇐` | 主动分心 | 占位符触发，二字完整命中 |
| `✂` | 主动分心截断 | 占位符触发，首字截断后继续 |

主动分心和被动分心都要校验首字是否等于已锁定首字，避免用户想要的首字被后续候选替换。

潜在分心还会通过 `get_syllable_aux_set()` 对第二音节做前瞻探路。如果第二码不可能命中下一音节，就不输出 `*x` / `✂` 诱导候选。

## 9. 长句断句和修音

长句模式由 `pattern_long` 进入：

```text
拼音;辅码;
拼音;辅码;s新音节
```

`parse_long_tail(S.raw_tail, trigger)` 只解析引导键后的尾部：

- 第二个引导键前是断句辅码。
- 连续引导键会被跳过。
- 后续文本是功能码。

`find_break_point()` 遍历首候选 preedit 切出的音节，调用 `get_syllable_aux_set()` 取音节可用辅码，再用 `combmath()` 判断是否命中。多个引导键会让它跳过前面的命中点。

修音分支的关键约束：

- 不直接修改 `inputspls`。
- 先复制到 `fresh_spls`。
- 对 `target_idx` 做越界检查。
- 用 `S.ybmodifiedcode` 交给 `longcandimodify_ybnotifier()` 重写输入。

## 10. 音节辅码集合

`get_syllable_aux_set(syllable)` 使用 Rime `Memory`：

1. 精确 `dict_lookup(syllable, false, 0)`。
2. 精确有结果时遍历 `iter_dict()`，只收集单字候选的辅码。
3. 精确结果没有单字时，fallback 到预测查询 `dict_lookup(syllable, true, 0)`。
4. 展开首码、完整双码；全码模式额外加入次码。
5. 只缓存精确匹配结果；预测结果不写长期缓存。

这样避免了简拼/前缀查询在不同上下文下污染缓存。

## 11. 智能指令

| 指令 | 作用 |
|---|---|
| `a` | 左偏移 1 字 |
| `s` | 左偏移 2 字；在长句功能码中也可作为修音前缀 |
| `d` | 右偏移 1 字 |
| `f` | 右偏移 2 字 |
| `w` | 跳过当前首候选 |
| `c/v/b/n` | 复制次数调整 |
| `t` | 首候选简繁转换 |
| `tXX` | 把首候选发送到本地 HTTP 接口 |
| `rXX` | 把原始输入发送到本地 HTTP 接口 |

外部请求依赖 `simplehttp` 和 `127.0.0.1:8080`。模块不可用时，基础辅码功能不受影响。

## 12. 调试

生产脚本写普通日志到 `<Rime 用户目录>/dic.log`。

调试脚本额外写 JSON Lines 到 `<Rime 用户目录>/debug_breakpoint.log`，可用 `docs/log_parser.html` 查看。调试事件包括：

- `session_start`
- `memory_init`
- `func_entry`
- `parse_input_code`
- `find_break_point_*`
- `notifier_*`
- `update_notifier`

## 13. 当前限制

- 断句、分心、修音都是低频纠偏能力，单次可能触发 `Memory:iter_dict()`，不应按普通热路径看待。
- `preedit_prefix_cache` 是 composition 级缓存，composition 结束会清理。
- `matchmode` 只有 `s` 被视为严格顺序；其他值都按全码兼容处理。
- `aux_v2_debug.lua` 的日志字段可能多于生产脚本状态字段，文档以生产脚本行为为准。
