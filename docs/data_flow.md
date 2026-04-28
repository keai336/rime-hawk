# 核心数据流图解

> 辅码插件的工作流程和数据转换过程

---

## 1. 主入口函数调用链

```
用户按键
  ↓
Rime Engine 调用 lua_filter
  ↓
AuxFilter.func(input, env)
  ↓
┌─────────────────────────────────────────────────────────────────┐
│  1. Update_codes(ctx)  — 解析输入字符串                          │
│     input: "zhongguo;vv;"                                       │
│     → S.inputCode = "zhongguo;vv;"                              │
│     → S.removeAuxInput = "zhongguo"                             │
│     → S.auxStr = ""                                             │
│                                                                 │
│  2. 模式匹配                                                    │
│     ┌──────────────┬──────────────────┬──────────────────────┐  │
│     │ "^[^;]+;     │ "^[^;]+;         │ 其他                 │  │
│     │  [%a,]*$"    │  %a*;+%a*$"      │                      │  │
│     │              │                  │                      │  │
│     │ main1()      │ longcandimodify()│ defaultmain()        │  │
│     │              │                  │                      │  │
│     │ 普通辅码     │ 断句+修音         │ 透传                 │  │
│     └──────────────┴──────────────────┴──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 辅码筛选流程 (main1)

```
输入: "zh;vv"
  ↓
process_input()
  → S.auxStr = "vv"
  → S.funccode = ""
  ↓
process_candidates()
  → 遍历所有候选词
  → 对每个候选词执行 main_main(env, cand)
      ↓
      ┌─────────────────────────────────────────────┐
      │ main_main()                                  │
      │                                              │
      │ 1. 获取候选词的辅码                          │
      │    ftext = "中"                               │
      │    auxCodes = aux_code["中"] → "ay"           │
      │    fullAuxCodes = fullAux("中") → {"a",""}    │
      │                                              │
      │ 2. 匹配辅码                                  │
      │    match(fullAuxCodes, "vv") → false          │
      │    → 不输出此候选词                          │
      │                                              │
      │ 1. 获取候选词的辅码                          │
      │    ftext = "重"                               │
      │    auxCodes = aux_code["重"] → "vv,...,"      │
      │    fullAuxCodes = fullAux("重") → {"v","v"}   │
      │                                              │
      │ 2. 匹配辅码                                  │
      │    match(fullAuxCodes, "vv") → true           │
      │    → yield_candisub(cand) → 输出              │
      └─────────────────────────────────────────────┘
```

---

## 3. 断句流程 (longcandimodify)

```
输入: "zhongguo;vv;"
  ↓
get_first_candidate()
  → "中国", preedit = "zhong guo"
  ↓
parse_input_code()
  → auxcode = "vv"
  → branchmark = 1 (断句模式)
  ↓
process_offsets()
  → inputspls = ["zhong", "guo"]
  → ficompensate = 2 (候选词字数)
  ↓
find_break_point(inputspls, "vv")
  ↓
  ┌──────────────────────────────────────────────────┐
  │ 遍历音节:                                        │
  │                                                  │
  │ index=1, syllable="zhong", zi="中"               │
  │   → get_syllable_aux_set("zhong")                │
  │   → fuset = {a:true, v:true, ...}                │
  │   → combmath("vv", fuset) → 检查 fuset["vv"]     │
  │   → false（zhong 的辅码不含 vv）                 │
  │                                                  │
  │ index=2, syllable="guo", zi="国"                 │
  │   → get_syllable_aux_set("guo")                  │
  │   → fuset = {l:true, v:true, vv:true, ...}       │
  │   → combmath("vv", fuset) → 检查 fuset["vv"]     │
  │   → true!（guo 的辅码包含 vv）                   │
  │   → ficompensate = 2, matchedmark = true         │
  │   → break                                       │
  └──────────────────────────────────────────────────┘
  ↓
ficompensate = 2 - 1 = 1
  ↓
candisub:new(firstcandi, ficompensate=1)
  → 截取前1个字: "中"
  ↓
yield("中")
```

---

## 4. 修音流程 (longcandimodify, branchmark=2)

```
输入: "zvjxgruz;ko;sge"
                              ↑ 修音标记
  ↓
parse_input_code()
  → auxcode = "ko"
  → ybmodif = "ge"（s后面的部分）
  → branchmark = 2 (修音模式)
  ↓
find_break_point()
  → ficompensate = 3 (匹配到的断点位置)
  ↓
修音分支 (branchmark == 2):
  ↓
  ┌──────────────────────────────────────────────────┐
  │ [V2 修复] 创建副本                               │
  │                                                  │
  │ inputspls = ["zv","jx","g","ruz"]  (缓存数组)    │
  │                  ↑                              │
  │            不能直接修改这个！                     │
  │                                                  │
  │ fresh_spls = ["zv","jx","g","ruz"]  (新数组)     │
  │                    ↑                             │
  │            可以安全修改                           │
  └──────────────────────────────────────────────────┘
  ↓
target_idx = ficompensate + 1 = 4
  ↓
[安全检查] target_idx 是否越界
  ↓
wrongyb = fresh_spls[4]  → "ruz"
fresh_spls[4] = "ge"     → 替换
  ↓
inputcode2 = "zvjxge" + table.concat
  ↓
S.ybmodifiedcode = "zvjxge;"
  ↓
yield("ruz->ge")  → 显示修改提示
```

---

## 5. 缓存策略

```
┌────────────────────────────────────────────────────────┐
│                   syllable_aux_cache                    │
│                                                        │
│  ┌─────────────┐    ┌─────────────┐                    │
│  │ "zhong"     │    │ "guo"       │                    │
│  │ ─────────── │    │ ─────────── │                    │
│  │ 精确匹配    │    │ 精确匹配    │  ← 缓存 ✅        │
│  │ 缓存: true  │    │ 缓存: true  │                    │
│  └─────────────┘    └─────────────┘                    │
│                                                        │
│  ┌─────────────┐                                       │
│  │ "q"         │    前缀匹配                           │
│  │ ─────────── │    结果不缓存 ← 不缓存 ❌            │
│  │ 每次重新查询│                                       │
│  └─────────────┘                                       │
│                                                        │
│  策略:                                                 │
│  - 精确匹配 → 缓存（可复用）                           │
│  - 前缀匹配 → 不缓存（避免内存爆炸）                   │
│  - 缓存失效 → 进程重启时自动清除                       │
└────────────────────────────────────────────────────────┘
```

---

## 6. 配置参数流

```
YAML 配置:
  lua_filter@aux_v2_debug@ZRM_Aux-code@on@;@`@,@s
                     │              │   │  │  │  │
                     ↓              ↓   ↓  ↓  ↓  ↓
              ┌──────────┐   ┌─────┐  │  │  │  │
              │ path =   │   │showor│  │  │  │  │
              │ ZRM_     │   │ = on│  │  │  │  │
              │ Aux-code │   └─────┘  │  │  │  │
              └──────────┘   ┌────────┘  │  │  │
                             │trigger = ;│  │  │
                             └───────────┘  │  │
                             ┌──────────────┘  │
                             │switch = `      │  │
                             └────────────────┘  │
                             ┌───────────────────┘
                             │ph = ,          matchmode = s
                             └─────────────────────────────┐
                                                           │
                             matchmode == "s" → 1 (简码模式)
                             matchmode == "m" → 0 (全码模式)
```

---

## 7. 智能指令解析

```
输入: "zhongguo;vv;adf"
                    ↑↑↑
                    ││└─ f → rightcompen += 2
                    │└── d → rightcompen += 1
                    └─── a → leftcompen += 1

解析结果:
  auxcode = "vv"
  funccode = "adf"
  leftcompen = 1
  rightcompen = 3

  ficompensate = 原始值 + min(0, rightcompen - leftcompen)
               = 原始值 + min(0, 3 - 1)
               = 原始值 + min(0, 2)
               = 原始值 + 0
               = 原始值

其他指令:
  w → skipc += 1    (跳过候选)
  c → dupc += 1     (复制次数+1)
  v → dupc *= 2     (复制次数×2)
  tXX → transor=true, trans_target=XX  (翻译)
  rXX → rawor=true, raw_target=XX      (原始翻译)
```