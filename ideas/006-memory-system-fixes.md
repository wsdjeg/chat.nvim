# 006 - 记忆系统实现缺口修正

**状态:** shipped — 实现位置：`lua/chat/memory/{init,daily,working,long_term}.lua`、
`lua/chat/tools/{extract_memory,recall_memory}.lua`、`lua/chat/plan.lua`；
回归测试见 `test/memory_fixes_spec.lua`

实现时额外发现并顺手修掉两个未列在此处的问题：

- `vim.json.encode(x, { indent = 2 })` 的 `indent` 必须是**字符串**，传数字会把
  字面量 `2` 拼进键名前（`2"memories"`），产出非法 JSON —— 受影响的
  `extract_memory` 返回值与 `long_term.export()` 备份都无法再解析/导入。
- `memory_fixes_spec` 初期失败全部源于测试自身的 `config.setup()` 深合并泄漏
  （`retention_days = 0`、`daily.enable = false` 跨用例残留），已改为每次
  `setup_config()` 落地完整基线。

## 动机

记忆系统三层架构(working / daily / long_term)与工具层(`@extract_memory`,
`@recall_memory`)已完整落地,121 个测试全绿。但逐行核对实现与文档后,发现
一批**功能实际失效**的缺口:工具层承诺的参数被丢弃、检索结果可能为空、
权重被重复叠加、开关无效。测试全绿是因为覆盖到的路径都是"能用"的路径,
失效路径恰好没被断言。

核心判断:**这些不是打磨,是文档承诺的行为不存在。** 模型按文档调用工具
会拿到错误结果(例如指定 `memory_type` 检索返回空),必须修。

## 问题清单

### 🔴 高优先级(功能实际失效)

| # | 位置 | 问题 | 后果 |
|---|------|------|------|
| 1 | `memory/init.lua:8` | `store_memory` 只接受 4 个参数,`metadata` 未转发 | `long_term.store` / `working.store` 的第 4 参永远是 nil |
| 2 | `tools/extract_memory.lua` | `detect_importance()` / `detect_work_type()` 算出结果后不传给 `store_memory`,批量分支连返回结果里都没有 `metadata` | `importance="high"`、`work_type="task"` 完全无效 |
| 3 | `tools/recall_memory.lua:183` | 跨类型取 top-N **后**再按 `memory_type` 过滤 | 指定类型时可能返回空,即使该类型有匹配但排在 limit 之外 |
| 4 | `memory/init.lua:20-41` | 权重双重叠加:`working.retrieve` 内已乘 `priority_weight`(2.0),init 再乘 2.0 → 4x;daily 模块内加分 + init ×1.5 | 文档写的 2.0x/1.5x 不成立,working 记忆挤占全部名额 |

### 🟡 中优先级(逻辑不一致 / 潜在崩溃)

| # | 位置 | 问题 |
|---|------|------|
| 5 | `daily.lua:58` | `retrieve` 未检查 `daily.enable`(long_term/working 都检查了)→ 关掉 daily 后旧记忆仍被检索 |
| 6 | `daily.lua` | `daily.max_memories = 100` 配置与文档都有,**代码从未实现**(long_term/working 都实现了裁剪)|
| 7 | `long_term.lua:112` | `a.metadata.confidence` 无 nil 保护 → `import()` 进的无 metadata 记忆在触发上限裁剪时报错 |
| 8 | `long_term.lua:308` | `original.metadata.confidence` 同样无保护(`merge_duplicates` 路径)|
| 9 | `long_term.lua:496` | `mem.metadata.category` 无保护 → `advanced_search{category=...}` 遇到无 metadata 记忆崩溃 |
| 10 | `long_term.lua:333` | `cleanup()` 条件 `confidence > 0.5 or access_count > 0`,而存入时 confidence 恒为 1.0 → **永远清不掉任何东西** |
| 11 | `memory/init.lua:53` | `M.cleanup()` 里 `working.cleanup_session()` 无参调用 → 默认清**当前会话**全部工作记忆,语义危险 |
| 12 | `memory.enable` | 全局开关只在 3 个工具入口检查,`memory/init.lua` 与 `chat/plan.lua:128/269` 都没检查 → 关掉后 plan 仍写工作记忆 |

### 🟠 核查中新发现(同一批修复顺手解决)

| # | 位置 | 问题 |
|---|------|------|
| 13 | `tools/recall_memory.lua` 重试分支 | 关键词重试用 `ctx.session` 而非 `target_session` → `all_sessions=true` 的重试又回到当前会话;重试后仍做后置过滤,#3 的缺陷在重试路径重现 |
| 14 | 三个 `retrieve` | 直接改写**持久化对象**:`mem.priority = ...` 写进存储记录,daily/working 还不 save(下次任意 save 才落盘);`recall_memory` 过滤掉的结果也已被计 `access_count` |
| 15 | `long_term.lua:142` | `memory.metadata.confidence` 在 `retrieve` 里无保护(与 #7 同类,只是这条会静默把候选排除而非报错)|
| 16 | `tools/extract_memory.lua` `detect_importance` | `'重要'` 同时出现在 critical 与 high 列表,且 critical 先查 → 中文 `'重要'` 永远命中 critical,`high` 不可达 |
| 17 | `tools/extract_memory.lua` 批量分支 | `metadata` 局部变量构造了但没放进 `extracted_memories` 条目(文本分支放了)→ 两条分支返回形状不一致 |
| 18 | `long_term.lua:174` | 检索后 `vim.defer_fn(save, 1000)` 异步落盘:测试可能读到旧计数,退出时可能丢失本会话的 access_count |

### 🟢 低优先级(质量/性能)

- `daily.get_stats()` 的 `expired` 恒为 0(`daily` 从不设置 `m.expired`,只有 working 设)。
- `daily` 存的 `expiry_days` 从未被读取,`cleanup_expired` 用全局 config 值 → 改配置会追溯影响所有旧记忆。
- `merge_duplicates()` 只比归一化后**完全相同**内容,与去重用的 0.85 阈值不一致,没复用 `similarity`。
- `text_similarity` 的 token 重合分母是 **query 的 token 数**,不是并集 → 短 query(2 个汉字)命中即 1.0,检索偏噪(Jaccard 更稳)。
- 每次 `store` 同步全量 `vim.json.encode` + 整文件重写,主线程 O(n);500 条无所谓,记忆体积大时卡顿。
- 每个模块 require 时 `M.load()` + 启动 timer(1h / 5min / 1week),无句柄无法关闭;`load()` 早于 `setup()` 会读默认路径。

## 方案

### 修复 1 + 2 + 17:metadata 一路透传

`init.store_memory` 加第 5 参并转发;**全局开关收口到 init**(顺手修 #12):

```lua
function M.store_memory(session, role, content, memory_type, metadata)
  if not config.config.memory or not config.config.memory.enable then
    return nil
  end
  memory_type = memory_type or 'long_term'
  local store = STORES[memory_type]
  if not store then return nil end
  return store(session, role, content, metadata)
end
```

`extract_memory` 两条分支都把 `metadata` 传下去**并**回填到结果条目;
批量分支的 `metadata` 合并调用方显式给出的 `work_type` / `importance`。

`detect_importance` 调整优先级:critical 只留真正的"紧急/必须/关键",
`'重要'` 归 high(中文语境下"重要"通常不是 critical):

| 级别 | 关键词 |
|------|--------|
| `critical` | 紧急、必须、关键、critical、urgent |
| `high` | 重要、优先、尽快、high、priority |
| `normal` | (默认) |

### 修复 3 + 13:先过滤类型,再 slice

`retrieve_memories` 加 `opts.memory_type`,**只查目标模块**(不再跨类型取
top-N 后过滤):

```lua
function M.retrieve_memories(query, session, limit, opts)
  opts = opts or {}
  local types = opts.memory_type and { opts.memory_type }
    or { 'working', 'daily', 'long_term' }
  -- 只有被检索的模块参与,每类各自 limit,最后全局排序 + slice
end
```

`recall_memory` 主路径与关键词重试路径都传 `opts.memory_type`,重试时用
`target_session`(而非 `ctx.session`)。重试后的后置过滤可以删掉——类型已在
源头过滤。

### 修复 4:权重只在模块层算一次

`memory/init.lua` **不再**乘任何权重,排序直接用模块返回的 `priority`。
权重下沉到各模块:

- `working.lua`:保持 `* (config.memory.working.priority_weight or 2.0)`
- `daily.lua`:新增 `* (config.memory.daily.priority_weight or 1.5)`,`priority_weight`
  进 config(与 working 同名同义)
- `long_term.lua`:1.0(不变)

文档里的 2.0x / 1.5x 因此成立,且只乘一次。

### 修复 14:检索不改写持久对象

模块返回**浅拷贝**(只拷展示/排序需要的字段),`priority` / `similarity` 写在
拷贝上:

```lua
local function to_view(mem, priority)
  return {
    id = mem.id, session = mem.session, role = mem.role,
    content = mem.content, timestamp = mem.timestamp,
    metadata = mem.metadata,      -- 引用即可,不写
    priority = priority,
  }
end
```

`long_term` 的 `access_count` / `last_accessed` 仍要更新(那是检索的语义),
但只更新**入选结果**并**同步**保存(替换 `vim.defer_fn`,修 #18)。

> 注意:`recall_memory` 带类型过滤时,被过滤掉的结果不应该计访问次数 ——
> 源头过滤(修复 3)天然解决。

### 修复 5 + 6 + 低优先级(daily)

```lua
function M.retrieve(query, limit)
  if not config.config.memory.daily.enable then return {} end   -- #5
  ...
end

-- store() 尾部,mirror long_term/working 的裁剪
local max_memories = config.config.memory.daily.max_memories or 100
if #daily_memories > max_memories then
  table.sort(daily_memories, function(a, b)
    local sa = (a.hit_count or 0) + (a.timestamp or 0) / 1e9
    local sb = (b.hit_count or 0) + (b.timestamp or 0) / 1e9
    return sa > sb
  end)
  daily_memories = vim.list_slice(daily_memories, 1, max_memories)
end
```

`cleanup_expired` 改用每条记忆自己的 `expiry_days`(不再读全局):

```lua
local now = os.time()
daily_memories = vim.tbl_filter(function(mem)
  local days = mem.expiry_days or config.config.memory.daily.retention_days
  return mem.timestamp >= now - days * 86400
end, daily_memories)
```

`get_stats().expired` 改为按上述条件**现算**(不再依赖从未被设置的
`m.expired` 标记)。

### 修复 7-10 + 15:long_term nil 保护与 cleanup 语义

三处 `mem.metadata.X` 统一改 `mem.metadata and mem.metadata.X`(排序打分用
`or 0` / `or 1.0`,`merge_duplicates` 里先 `original.metadata = original.metadata or {}`)。

`cleanup()` 原条件恒真,改成**真实的陈旧淘汰**:

```lua
local STALE_SECONDS = 90 * 86400
-- 保留:被访问过,或足够新
return access_count > 0 or (now - (mem.timestamp or 0)) < STALE_SECONDS
```

即"90 天从未被检索过的记忆"才会被清掉,与 `max_memories` 的按分数裁剪是两套
策略,不再互相遮蔽。

### 修复 11:cleanup 不动当前会话

```lua
function M.cleanup()
  if not enabled() then return end
  long_term.cleanup()
  daily.cleanup_expired()
  working.cleanup_expired()   -- 只清 TTL 过期,不按会话清
end
```

按会话清记忆仍走 `clear_session_memories(session)`,显式传参。

### 文档(docs/memory.md)

- 存储布局改成实际三个扁平文件:
  ```
  storage_dir/memory/
  ├── working_memories.json
  ├── daily_memories.json
  └── long_term_memories.json
  ```
- 配置表补 `daily.priority_weight`;`working.priority_weight` 说明改为"模块层乘一次"
- 明确 `importance` / `work_type` 只对 working 生效且已生效
- `cleanup()` 语义补一句:90 天未访问淘汰,不按会话清理

## 设计决策

1. **开关收口到 `memory/init.lua`,不在每个调用点补检查。** 12 条问题里
   有 1 条就是"3 个工具入口检查、init 和 plan 没检查";补第 4、5 个检查点
   只是把问题往后挪。init 是唯一 choke point,plan 自动被覆盖。
2. **类型过滤在源头,不在结果上。** 后置过滤的缺陷是**信息已丢失**——
   top-N 里没有的东西无法恢复。加 `opts.memory_type` 是唯一正确解,
   重试路径也一并修好。
3. **权重下沉模块而不是在 init 算。** init 不知道每类的语义加分
   (working 的 session/importance/recency、daily 的 recency),在那里乘系数
   必然与模块内部逻辑打架。让模块出自己的最终分,init 只排序。
4. **检索返回视图对象,不返回存储对象。** 原实现把 `priority` 写进持久化
   记录,任何一次 `save` 都会把检索态落盘。拷贝是零成本的(`metadata` 用
   引用共享)。
5. **`access_count` 同步保存。** `vim.defer_fn(1000)` 的本意是避免频繁 IO,
   但代价是退出丢计数、测试读旧值。记忆检索频率远低于消息,同步 save 更简单
   可靠。
6. **`cleanup()` 用"陈旧+零访问"而不是"低置信度"。** confidence 目前没有
   任何下调路径,基于它的淘汰条件永远是空操作。按时间淘汰是可观测、
   可测试的真实策略。
7. **daily 的 `expiry_days` 按记忆自身读取。** 配置变更不应追溯改写历史
   记忆的寿命,这与 long_term 的"存入时快照"思路一致。

## 风险 / 未决问题

- **行为变化**:去掉双重加权后 working 记忆的分值下降一半(4x → 2x)。
  排序结论可能变化,属期望内的修正。
- **行为变化**:`cleanup()` 从空操作变成真会删数据。默认 90 天窗口足够宽松,
  但第一次上线时应提示用户;不做自动迁移。
- `memory.daily.priority_weight` 是新增配置键,老用户配置文件不含它 → 走默认
  1.5,无迁移成本。
- 视图对象意味着调用方拿不到 `access_count` / `hit_count` / `ttl`。
  `recall_memory` 的输出本来只展示 content/type/time,不受影响;
  `picker/sources/chat_memory.lua` 走 `get_memories()`,也不受影响。
- `similarity` 的 token 分母、`merge_duplicates` 复用相似度、增量写入、
  timer 句柄**不在本次范围**——它们不改语义,留作后续打磨。

## 测试要点

- metadata 透传:`store_memory(..., 'working', { importance = 'critical' })`
  → `working.get_session_memories()` 里该条 `metadata.importance == 'critical'`
- extract_memory:`importance="high" work_type="task"` 后检索到的记忆带这两项;
  批量分支返回条目含 `metadata`;`detect_importance('这很重要')` → `high`
- recall 类型过滤:`limit=3` 且只有第 5 条是 daily 时,`memory_type="daily"`
  仍能返回它(原实现返回空)
- 权重:同一 query 下 working 记忆的 `priority` ≈ 原始分 ×2.0,**不是** ×4.0;
  daily ≈ ×1.5
- 检索纯函数性:连续两次 `retrieve` 后存储记录里的 `priority` 不变,
  `daily.get_all()` 不含 `priority` 字段
- daily 开关:`daily.enable = false` 时 `retrieve` 返回 `{}`
- daily 上限:写入 101 条后只留 100,且被丢的是 `hit_count` 最低的
- daily 寿命:`expiry_days = 3` 的旧记忆在 `retention_days = 7` 下仍被清理
- nil 保护:`import()` 无 metadata 的记忆触发上限裁剪 / `advanced_search`
  / `merge_duplicates` 均不报错
- cleanup:90 天未访问的被删;访问过的、新存入的都保留
- `M.cleanup()` 不删当前会话未过期的记忆
- 全局开关:`memory.enable = false` 时 `store_memory` 返回 nil(plan 写入也无效果)

## 修复顺序

1. `memory/init.lua`:metadata 透传 + 开关收口 + 权重只算一次 + cleanup 语义
   (#1 #4 #11 #12)
2. `tools/extract_memory.lua`:metadata 透传/回填 + importance 关键字 (#2 #16 #17)
3. `tools/recall_memory.lua`:源头类型过滤 + 重试路径 (#3 #13)
4. `memory/daily.lua`:enable + max_memories + expiry_days + stats (#5 #6)
5. `memory/long_term.lua`:三处 nil 保护 + cleanup 条件 + 同步 save (#7 #8 #9 #10 #15 #18)
6. `memory/working.lua` / `memory/daily.lua`:返回视图对象 (#14)
7. `docs/memory.md` + `docs/configuration.md`:存储布局与配置表
8. 补测试 → `make test` 全绿 → 提交

