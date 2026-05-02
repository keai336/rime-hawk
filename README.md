<p align="center">
  <img src="docs/icon.png" alt="Rime Hawk Logo" width="112" />
</p>

# Rime Hawk

Rime Hawk 是一个 Rime Lua 候选过滤器，用「拼音 + 辅码」筛选候选字词。它不接管输入方案的拼音解析，只在候选列表后处理阶段工作，因此可以叠加到现有方案上。

适合这些场景：

- 同音字多，希望用一到两位辅码快速定位。
- 偶尔需要逐字筛选、长句断句或修正手滑音节。
- 希望辅码逻辑独立于主词库，方便替换辅码表。

## 快速安装

1. 将这些文件放到 Rime 用户目录的 `lua/` 下：

```text
aux_v2.lua
aux_v2_debug.lua        # 可选，调试版
test5.txt              # 示例辅码表，可替换
```

2. 在输入方案的 `.schema.yaml` 中加入过滤器：

```yaml
speller:
  # 建议包含插件用到的符号：引导键 ;、切换键 `、占位符 ,
  alphabet: zyxwvutsrqponmlkjihgfedcba;`,

engine:
  filters:
    - lua_filter@aux_v2@test5@on@;@`@,@s
```

3. 如果方案已有 `translator/preedit_format`，请改名为 `preedit_format1`，交给 Hawk 内部读取：

```yaml
translator:
  preedit_format1:
    - xform/.../.../
```

4. 重新部署 Rime。

## 配置参数

过滤器挂载格式：

```text
lua_filter@aux_v2@path@showor@trigger@switch@ph@matchmode
```

| 参数 | 默认示例 | 说明 |
|---|---:|---|
| `path` | `test5` | 辅码表文件名，不带 `.txt` |
| `showor` | `on` | 是否在候选注释中显示辅码 |
| `trigger` | `;` | 辅码引导键 |
| `switch` | `` ` `` | 单字模式切换键 |
| `ph` | `,` | 占位符，用于主动分心等功能 |
| `matchmode` | `s` | 匹配模式，`s` 为严格顺序 |

## 辅码表格式

辅码表是 UTF-8 文本，每行一字，以制表符分隔字和辅码：

```text
踩	pe
心	hh
仪	jb
```

一个字可以有多个辅码，用逗号分隔：

```text
重	vs,is
```

## 基础用法

| 输入 | 作用 |
|---|---|
| `cai` | 正常输入，不启用辅码过滤 |
| `cai;p` | 按首码 `p` 过滤候选 |
| `cai;pe` | 按双码 `pe` 精确过滤 |
| `cai;pew` | 过滤后追加智能指令，例如跳过首候选 |

示例：

```text
cai
① 踩(pe)  ② 菜(le)  ③ 才(nt)

cai;p
① 踩(pe)
```

## 常用指令

在辅码后追加以下字母可以调整候选截取：

| 指令 | 作用 |
|---|---|
| `a` | 左偏 1 字 |
| `s` | 左偏 2 字 |
| `d` | 右偏 1 字 |
| `f` | 右偏 2 字 |
| `w` | 跳过当前首候选 |

示例：

```text
pinyin;abw
```

表示先按辅码 `ab` 过滤，再跳过当前首候选。

## 高级功能

这些功能不是日常主路径，按需使用即可。它们仍然遵循同一个原则：先修正最左边第一个不合意的位置，再处理剩余输入。

### 最佳实践：盯住第一个不合意的字

- 从左到右看候选，先找第一个不合意的字或词段。
- 只围绕这个位置使用辅码筛选；需要切分歧义时，再用断句、分心或修音。
- 前缀正确后先确认，让剩余拼音继续留在候选区处理。
- 断句和分心是低频纠偏操作，日常优先使用普通辅码过滤。
- 具体案例见 [最佳实践详解](docs/best_practices.md)。

### 单字模式

输入辅码引导键后按切换键 `` ` ``，进入逐字筛选。

```text
danzi;`
```

确认一个字后，后续音节继续按辅码筛选；本轮结束后自动恢复词组模式。

### 分心机制

二字词输入两位辅码时，如果不能作为完整单字辅码匹配，Hawk 可以将两位辅码分配给词组的前后两个字。

| 标记 | 含义 |
|---|---|
| `**` | 双码分别命中二字词的两个字 |
| `*x` | 首字命中，次码保留给下一轮 |
| `⇐` | 主动分心且完整命中 |
| `✂` | 主动分心并截断 |

主动分心使用占位符 `,`：

```text
xinyi;hj,
```

### 长句断句

在辅码后追加第二个引导键，按辅码命中的位置截断长句：

```text
input;ab;
```

适合长句中间某个音节被错误组词时手动切分。

### 修音

断句定位后，可以用 `s` 指令替换目标音节：

```text
input;ab;sge
```

表示将定位到的音节改为 `ge` 后重新组词。

### 转换和外部请求

| 指令 | 作用 |
|---|---|
| `t` | 对首候选做简繁转换 |
| `tXX` | 将首候选发送到本地 HTTP 接口 |
| `rXX` | 将原始拼音发送到本地 HTTP 接口 |

外部请求依赖可选模块 `simplehttp` 和本地 `127.0.0.1:8080` 服务。未配置时不会影响基础辅码筛选。

## 文件说明

```text
.
├── aux_v2.lua                         # 正常使用版
├── aux_v2_debug.lua                   # 调试版
├── test5.txt                          # 示例辅码表
├── docs/
│   ├── technical_docs.md              # 技术设计
│   ├── data_flow.md                   # 数据流说明
│   ├── api_reference.md               # API 速查
│   ├── best_practices.md              # 最佳实践详解
│   ├── log_parser.html                # JSONL 调试日志查看器
│   └── performance_optimization_report.html
```

## 调试

- 普通日志：`<Rime 用户目录>/dic.log`
- 调试日志：使用 `aux_v2_debug.lua`，日志写入 `<Rime 用户目录>/debug_breakpoint.log`
- 日志查看：打开 `docs/log_parser.html`

## 相关文档

- [技术设计](docs/technical_docs.md)
- [数据流说明](docs/data_flow.md)
- [API 速查](docs/api_reference.md)
- [最佳实践详解](docs/best_practices.md)
- [性能优化报告](docs/performance_optimization_report.html)

## 致谢

- [HowcanoeWang/rime-lua-aux-code](https://github.com/HowcanoeWang/rime-lua-aux-code)
- [RIME | 中州韵输入法引擎](https://rime.im/)
