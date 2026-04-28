# aux_v2_debug.lua 技术文档

> Rime 输入法辅码过滤插件 | 版本: v2_debug | 日期: 2026-04-25

---

## 1. 概述

`aux_v2_debug.lua` 是一个 Rime 输入法 Lua 过滤器插件，用于实现辅码（辅助编码）功能。

### 1.1 什么是辅码？

辅码是一种辅助输入编码，用于在输入拼音后进一步筛选候选字/词。例如：
- 输入 `zh;vv` → 只显示拼音为 "zh" 且辅码包含 "vv" 的候选词
- 用于五笔、郑码等形码输入法的辅助筛选

### 1.2 核心能力

| 功能 | 说明 |
|------|------|
| 辅码筛选 | 根据辅码过滤候选词 |
| 断句功能 | 长句自动在匹配点截断 |
| 修音功能 | 修改已输入的拼音音节 |
| 智能指令 | 支持偏移、复制、翻译等操作 |

---

## 2. 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      Rime 输入引擎                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  输入 "zh;vv;"                                               │
│      ↓                                                      │
│  ┌─────────────────┐                                         │
│  │ func()          │ ← 入口函数，分发到各处理分支            │
│  └────────┬────────┘                                         │
│           ↓                                                  │
│  ┌────────┴────────────────────────────────────────┐        │
│  │                    模式匹配                        │        │
│  ├───────────────┬───────────────┬──────────────────┤        │
│  │ pattern_main1 │ pattern_long  │ pattern_default  │        │
│  │   普通辅码    │  长句/断句/修音 │    透传         │        │
│  └───────┬───────┴───────┬───────┴───────┬──────────┘        │
│          ↓               ↓               ↓                   │
│  ┌───────┴───────┐ ┌─────┴─────┐ ┌───────┴────────┐          │
│  │ main1()      │ │ longcandi-│ │ defaultmain() │          │
│  │              │ │ modify()  │ │                │          │
│  │ 普通辅码筛选  │ │ 断句+修音  │ │ 直接透传候选   │          │
│  └──────────────┘ └───────────┘ └────────────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 核心数据结构

### 3.1 状态对象 `AuxFilter.state`

```lua
S = {
    -- 辅码相关
    auxStr = "",         -- 辅码字符串，如 "vv"
    funccode = "",       -- 功能码，如 "a", "d", "w"

    -- 断句相关
    ficompensate = nil,  -- 断点位置
    matchedmark = false, -- 是否找到匹配
    leftcompen = 0,      -- 左偏移
    rightcompen = 0,     -- 右偏移

    -- 修音相关
    ybmodifiedcode = "", -- 修音后的编码

    -- 其他
    single_flag = false, -- 单字筛选模式
    counter = 0,         -- 已输出候选计数
    dupc = 1,            -- 复制次数
    transor = false,     -- 翻译开关
}
```

### 3.2 配置文件

```lua
AuxFilter = {
    trigger_key = ";",      -- 触发键
    ph = ",",               -- 辅码分隔符
    switch_key = "`",       -- 单字切换键
    matchmode = 1,          -- 0=全码模式, 1=简码模式
    show_aux_notice = true,-- 显示辅码提示
    aux_code = {},          -- 字→辅码映射表
}
```

### 3.3 缓存

| 缓存名 | 键 | 值 | 说明 |
|--------|----|----|------|
| `syllable_aux_cache` | 音节字符串 | 辅码布尔哈希表 / `false` | 进程级，精确匹配时缓存；`false` 表示查询失败 |
| `pinyin_cache` | 拼音原始字符串 | 音节字符串数组 | 空格切分结果缓存 |
| `fullAuxCache` | 词文本 | `{首码串, 次码串}` | 多字词按需计算的完整辅码缓存 |
| `AuxFilter.fullAux_precomputed` | 单字文本 | `{首码串, 次码串}` | 启动时预计算的单字辅码，O(1) 查询 |

> `utf8lenCache` 已移除，改用标准库 `utf8.len()`。

---

## 4. 核心函数详解

### 4.1 `get_syllable_aux_set(syllable)`

**功能**: 获取某个拼音音节对应的辅码集合（通过 Memory API 动态查询词典）

**参数**:
- `syllable`: 拼音音节，如 `"zhong"`, `"q"`

**返回值**: 辅码展开集合（布尔哈希表），如 `{["v"]=true, ["vv"]=true, ...}`；查询失败返回 `nil`

**核心流程**:
```lua
local function get_syllable_aux_set(syllable)
    -- 1. 缓存命中直接返回（false 表示已知查无结果）
    local cached = syllable_aux_cache[syllable]
    if cached then return cached end

    -- 2. 精确匹配（predictive=false, limit=0）
    local lookup_result = mem:dict_lookup(syllable, false, 0)
    local is_predictive = false

    if lookup_result then
        -- 遍历 iter_dict，收集所有单字的辅码
        raw_aux_set, char_list, has_any, single_char_count = collect_aux_from_iter("exact")

        -- 精确匹配成功但无单字结果 → fallback 到前缀匹配
        if single_char_count == 0 then
            lookup_result = nil
        end
    end

    -- 3. 精确匹配无效，fallback 前缀匹配（predictive=true）
    if not lookup_result then
        lookup_result = mem:dict_lookup(syllable, true, 0)
        is_predictive = true
        if lookup_result then
            raw_aux_set, char_list, has_any, single_char_count = collect_aux_from_iter("predictive")
        end
    end

    -- 4. 两种方式均失败，仅精确失败时缓存 false
    if not lookup_result or not has_any then
        if not is_predictive then
            syllable_aux_cache[syllable] = false
        end
        return nil
    end

    -- 5. 展开辅码（首码 + 全码；matchmode==0 时额外添加次码）
    for key in pairs(raw_aux_set) do
        expanded[key:sub(1, 1)] = true
        if matchmode == 0 then expanded[key:sub(2, 2)] = true end
        expanded[key] = true
    end

    -- 6. 仅精确匹配结果写入缓存，前缀匹配不缓存
    if not is_predictive then
        syllable_aux_cache[syllable] = expanded
    end

    return expanded
end
```

> **关键设计**：`is_predictive` 标志替代了旧版 `no_cache` 参数，逻辑内聚在函数体内。

### 4.2 `find_break_point(inputspls, auxcode)`

**功能**: 在音节数组中找到辅码匹配的断点位置

**参数**:
- `inputspls`: 音节数组，如 `["zh", "i", "nan"]`
- `auxcode`: 辅码，如 "vv"

**返回值**: 找到匹配时 `matchedmark=true`，`ficompensate=截断位置`

**核心流程**:
```lua
function find_break_point(inputspls, auxcode)
    for index, syllable in ipairs(inputspls) do
        local zi = utf8sub(ftext, index, index)  -- 当前汉字
        local fuset = get_syllable_aux_set(syllable)  -- 获取辅码集合

        -- 匹配辅码
        if combmath(auxcode, fuset) then
            ficompensate = index
            matchedmark = true
            break
        end
    end
    return matchedmark
end
```

### 4.3 `combmath(aux, fuset)`

**功能**: 判断辅码是否匹配

```lua
local function combmath(aux, fuset)
    if #aux == 0 then return true end        -- 无辅码默认全匹配
    if not fuset then return false end        -- 辅码集合为 nil
    -- matchmode==1（简码）: 仅正向查表
    -- matchmode==0（全码）: 正向 + 反转均可匹配
    return fuset[aux] or (AuxFilter.matchmode == 0 and fuset[aux:reverse()])
end
```

> **注意**：全码模式（`matchmode=0`）下 `"ab"` 和 `"ba"` 视为等价辅码。

---

## 5. 输入模式与处理分支

### 5.1 普通辅码模式

**输入格式**: `拼音;辅码`

**示例**: `zh;vv`

**流程**:
```
输入 "zh;vv"
  ↓
pattern_main1 匹配成功
  ↓
main1() 处理
  ↓
获取候选词 → 过滤辅码 → 输出
```

### 5.2 长句断句模式

**输入格式**: `拼音;辅码;`

**示例**: `zhongguo;vv;`

**流程**:
```
输入 "zhongguo;vv;"
  ↓
pattern_long 匹配成功（两个及以上分号）
  ↓
longcandimodify() 处理
  ↓
find_break_point() 查找断点
  ↓
截取匹配位置前的汉字输出
```

### 5.3 修音模式

**输入格式**: `拼音;辅码;s新音节`

**示例**: `zhong;sguo`（把 zhong 改成 guo）

**流程**:
```
输入 "zhong;sguo"
  ↓
识别功能码 "sguo"（s开头表示修音）
  ↓
分离出新音节 "guo"
  ↓
修改 inputspls 中的音节
  ↓
重新生成输入码
```

---

## 6. 智能指令系统

### 6.1 偏移指令

| 指令 | 效果 |
|------|------|
| `a` | 左偏移 1 字符 |
| `s` | 左偏移 2 字符 |
| `d` | 右偏移 1 字符 |
| `f` | 右偏移 2 字符 |

### 6.2 复制指令

| 指令 | 效果 |
|------|------|
| `c` | 复制次数 +1 |
| `v` | 复制次数 ×2 |
| `n` | 复制次数 -1 |

### 6.3 翻译指令

格式: `t目标`（如 `ten` 翻译为英文）

---

## 7. 关键修复记录

### 7.1 v2: 修音崩溃修复

**问题**: 修音分支直接修改 `inputspls` 数组，污染 `split_pinyin()` 缓存

**修复**: 创建副本 `fresh_spls`，不直接修改原数组

```lua
-- 修复前（有bug）
inputspls[S.ficompensate + 1] = ybmodif

-- 修复后
local fresh_spls = {}
for i, v in ipairs(inputspls) do
    fresh_spls[i] = v
end
fresh_spls[S.ficompensate + 1] = ybmodif
```

### 7.2 前缀匹配缓存控制

**问题**: 前缀匹配 `predictive=true` 会跨音节匹配，不同上下文结果不同，若缓存会导致错误命中或内存爆炸

**修复**: 引入 `is_predictive` 标志，前缀匹配结果不写入缓存

```lua
-- 旧方案（有 no_cache 参数，已废弃）
local function get_syllable_aux_set(syllable, no_cache) ... end

-- 当前方案（is_predictive 内聚于函数体）
local is_predictive = false
if not lookup_result then
    lookup_result = mem:dict_lookup(syllable, true, 0)
    is_predictive = true
end
-- ...
if not is_predictive then
    syllable_aux_cache[syllable] = expanded  -- 仅精确匹配结果缓存
end
```

---

## 8. 调试系统

### 8.1 日志开关

```lua
local DEBUG_MODE = true  -- 设为 false 关闭日志
```

### 8.2 日志格式

JSON Lines 格式，输出到 `用户数据目录/debug_breakpoint.log`

### 8.3 关键日志事件

| 事件 | 说明 |
|------|------|
| `session_start` | 会话开始 |
| `get_syllable_aux_set` | 音节辅码查询 |
| `find_break_point_loop` | 断点查找循环 |
| `longcandimodify_*` | 长句处理各阶段 |

---

## 9. 配置参数

在 YAML 中配置：

```yaml
filters:
  - lua_filter@aux_v2_debug@ZRM_Aux-code@on@;@`@,@s
```

参数顺序（用 `@` 分隔）：
1. `path` - 辅码文件路径（不含扩展名）
2. `showor` - 显示辅码提示（on/off）
3. `trigger` - 触发键（默认 `;`）
4. `switch` - 单字切换键（默认 `` ` ``）
5. `ph` - 辅码分隔符（默认 `,`）
6. `matchmode` - 匹配模式（s=简码，m=全码）

---

## 10. 文件结构

```
lua/refactor/
├── aux_v2_debug.lua        # 主脚本（当前版本）
└── docs/
    ├── technical_docs.md   # 技术文档（本文件）
    ├── api_reference.md    # API 速查手册
    └── data_flow.md        # 数据流图解
```

---

## 11. 常见问题

### Q1: 简拼断句失败？

**原因**: 简拼 "q" 不是完整音节，`dict_lookup` 精确匹配失败

**解决方案**: 前缀匹配作为 fallback（当前已实现）

### Q2: 内存占用大？

**原因**: 缓存未及时清理

**解决方案**: 前缀匹配结果不缓存，定期重启输入法

### Q3: 辅码不显示？

**检查**:
1. 辅码文件是否存在
2. 触发键是否正确
3. 候选词是否有辅码配置

---

## 12. 联系方式与参考

- 原始项目: Rime 输入法
- Lua 插件: librime-lua
- 辅码格式: 详见 ZRM_Aux-code 配置文件