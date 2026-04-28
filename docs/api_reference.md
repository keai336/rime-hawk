# API 速查手册

> aux_v2_debug.lua 对外/对内接口参考

---

## 1. Rime Filter 接口

### `AuxFilter.func(input, env)`
主入口，Rime 每次刷新候选时调用。

### `AuxFilter.init(env)`
初始化，加载配置和辅码文件。

### `AuxFilter.fini(env)`
析构，断开通知器连接，关闭日志文件。

---

## 2. 处理分支

### `AuxFilter.main1(input, env)`
**触发条件**: 输入匹配 `^[^;]+;[%a,]*$`

**功能**: 普通辅码筛选

### `AuxFilter.longcandimodify(input, env)`
**触发条件**: 输入匹配 `^[^;]+;%a*;+%a*$`（含两个以上分号）

**功能**: 断句、修音

### `AuxFilter.defaultmain(input, env)`
**触发条件**: 不匹配其他模式

**功能**: 直接透传所有候选

---

## 3. 辅码系统

### `get_syllable_aux_set(syllable, no_cache)`
| 参数 | 类型 | 说明 |
|------|------|------|
| syllable | string | 拼音音节 |
| no_cache | bool | 是否不缓存（内部使用） |
| 返回 | table/nil | 辅码集合 `{["vv"]=true,...}` |

### `combmath(aux, fuset)`
| 参数 | 类型 | 说明 |
|------|------|------|
| aux | string | 辅码（1-2字符） |
| fuset | table | 辅码集合 |
| 返回 | bool | 是否匹配 |

### `AuxFilter.fullAux(env, word)`
| 参数 | 类型 | 说明 |
|------|------|------|
| word | string | 汉字（1-多字） |
| 返回 | table | `{首码串, 次码串}` |

### `AuxFilter.match(fullAux, auxStr)`
| 参数 | 类型 | 说明 |
|------|------|------|
| fullAux | table | fullAux 返回值 |
| auxStr | string | 辅码字符串 |
| 返回 | bool | 是否匹配 |

---

## 4. 断句系统

### `find_break_point(inputspls, auxcode)`
| 参数 | 类型 | 说明 |
|------|------|------|
| inputspls | table | 音节数组 `{"zhong","guo"}` |
| auxcode | string | 辅码 `"vv"` |
| 返回 | bool | 是否找到匹配 |

**副作用**: 更新 `S.ficompensate`（截断位置）。`matchedmark` 为局部变量，仅在该函数内有效。

---

## 5. 工具函数

### `split_pinyin(pinyin_str)`
按空格切分拼音字符串，带缓存。

### `utf8len(str)` / `utf8sub(str, i, j)`
UTF-8 字符串长度/子串。

### `countSubstringOccurrences(str, substr)`
统计子串出现次数。

### `parseIntelligentCode(funccode)`
解析智能指令，返回偏移/复制/翻译参数对象。

### `AuxFilter.readAuxTxt(txtpath)`
读取辅码文件，将其写入 `AuxFilter.aux_code`，同时预计算单字辅码并写入 `AuxFilter.fullAux_precomputed`。

---

## 6. 通知器回调

| 标记 | 回调 | 说明 |
|------|------|------|
| 1 | `main1_notifier` | 普通辅码选中 |
| 2 | `longcandimodify_notifier` | 断句选中 |
| 3 | `longcandimodify_ybnotifier` | 修音选中 |

---

## 7. 状态对象字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `S.inputCode` | string | 原始输入码 |
| `S.precode` | string | 预编辑文本 |
| `S.removeAuxInput` | string | 去除辅码的输入 |
| `S.auxStr` | string | 辅码 |
| `S.funccode` | string | 功能码 |
| `S.ficompensate` | number | 截断位置 |
| `S.counter` | number | 已输出候选数 |
| `S.single_flag` | bool | 单字模式 |
| `S.notifiermark` | number | 当前通知器标记 |
| `S.transedtext` | string | 翻译后的文本 |