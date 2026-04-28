# Rime 辅码插件重构分支 - 版本历史

## v2 (2026-04-23) ★ 推荐使用
**修复：修音崩溃 Bug**

- **问题**：修音分支中直接修改 `inputspls` 数组，污染了 `split_pinyin()` 缓存，导致下一轮访问越界崩溃
- **修复**：
  1. 修音分支创建 `inputspls` 的副本 (`fresh_spls`)，不直接修改原数组
  2. 增加越界安全检查，防止 `ficompensate + 1` 超出数组范围

**相关文件**：`aux_v2_debug.lua`

---

## v1 (2026-04-22) - 核心重构
**重构目标**：消除配置文件中的音码列，用 Memory API 替代 `comb_code[音码]`

- **删除**：`comb_code`、`zi_to_yin`、`comb_expanded`、`best_match()`、`two_char_combinations()`
- **新增**：`syllable_aux_cache`、`get_syllable_aux_set()`、Memory 对象初始化
- **内存节省**：~60%

**已知问题**：
- ❌ 简拼断句可能失败（`dict_lookup` 对简拼音节可能返回空）

---

## 目录结构

```
lua/refactor/
├── aux_v2_debug.lua    # v2 修复版（推荐使用）
└── .git/               # 独立 Git 仓库
```

---

## 部署

复制 `aux_v2_debug.lua` 到 Rime 用户目录后，方案 YAML 配置：
```yaml
filters:
  - lua_filter@aux_v2_debug@ZRM_Aux-code@on@;@`@,@s
```

---

## 待解决问题

### 简拼断句问题
- **症状**：简拼（如 `loq`）断句可能失败
- **原因**：`dict_lookup("loq")` 可能返回空（词典中无此音节）
- **方案**：保留 `zi_to_yin` 作为模糊匹配兜底