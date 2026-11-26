# 005 - get_history 结果语义与体积预算打磨

**状态:** shipped — `feat(tools): complete get_history result semantics`

## 动机

`get_history` 已经加了字节预算(`max_bytes`,见提交
`feat(tools): cap get_history result by byte budget`),但**返回的内容本身**
仍有语义问题:历史里混着非对话条目、工具调用不可读、两套编号混用、search
语义与项目其它搜索不一致。这些都不是"打磨",模型拿到的结果会**读错**。

## 现状问题清单

| # | 问题 | 后果 |
|---|------|------|
| 1 | `on_complete` 标记(只有 `usage`,无 role/content)被当成消息返回 | `total` 虚高、`limit` 名额被占、字节预算被空条目吃掉 |
| 2 | `working_set` 只保留 `index/role/content/created` | assistant 的 `tool_calls` 丢失 → 模型看到"空的 assistant";tool 结果不知道是哪个工具 |
| 3 | `next_offset`(过滤后的位次)和 `index`(全局下标)混在同一个 note 里 | 开 search 后两个数字不是一回事,模型取错位置 |
| 4 | `get_history` 只匹配 `content`,`sessions/messages.lua: search_messages()` 匹配 `content + reasoning_content` | 同一个项目里两个"搜索"定义,长期必然对不上 |
| 5 | `limit ≤ 50` 与字节上限并存 | 短消息时 50 条才 1KB,字节预算形同虚设,模型永远取不全一屏能装下的历史 |
| 6 | 整条装不下时 `next_offset` 回指同一条 | 模型不理会 note 就会拿到**一模一样**的结果,来回死循环 |
| 7 | 错误分支返回裸文本,正常分支返回 JSON | 调用方要处理两种形态 |
| 8 | `32768 / 2048 / 204800` 硬编码 | 1M 上下文模型想一次读 400KB 也没辙 |
| 9 | 负数 `offset` 被静默 clamp 成 0 | "最后 20 条"实际返回**最早** 20 条,语义相反 |

## 方案

### 1 + 7: 条目分类与统一响应

历史里只有三类条目属于对话:`user` / `assistant` / `tool`。其余分为:

- `error` / `notice`:无 role,但**有信息量**,保留并打 `kind` 标签
- 其它(`on_complete` 的 usage 标记):纯记账,直接丢弃

```lua
local CONVERSATIONAL_ROLES = { 'user', 'assistant', 'tool' }

local function classify(msg)
  if msg.role ~= nil and vim.tbl_contains(CONVERSATIONAL_ROLES, msg.role) then
    return 'message'
  end
  if msg.error ~= nil then return 'error' end
  if msg.notice ~= nil then return 'notice' end
  return nil  -- bookkeeping marker
end
```

`total` 改为**对话条目数**(过滤后),错误分支也返回 JSON 骨架
(`total / returned / messages / note / bytes`),调用方只解析一种形状。

### 2: 工具上下文(只回填名字)

```lua
assistant: tool_calls = { "read_file", "git_add" }  -- 仅名字,不回填 arguments
tool:      tool = "git_diff"                        -- 对应工具名
```

arguments 不回填:模型需要的是"调了什么",参数在它自己的上下文里。

### 3 + 6: 稳定分页 + 可执行的截断提示

- `next_offset`:working set 位次(分页用,保持现状)
- `next_message_index`:全局消息下标(定位用),两者同时给出
- 整条装不下时算**精确够用的预算**并写进 note,让模型一次做对:

```lua
layout.required_bytes = max_bytes + (size - remaining) + 16
```

note 从"请调大"变成 `retry with max_bytes=NNNN`。

### 4: 搜索谓词复用

`get_history` 不再自己写匹配,改为调用
`chat.sessions.messages.search_messages()`(content + reasoning_content),
把返回的 1-based 下标映射成工作集。一条知识两处定义 → 一处实现。

### 5: 条数上限让位给字节上限

`limit` 上限 50 → 200。既然有硬字节上限,条数上限就是冗余约束;
`offset` 分页仍能保证有界。

### 8: 预算进 config

```lua
require('chat').setup({
  tools = {
    get_history = {
      default_max_bytes = 32768,   -- 省略 max_bytes 时使用
      max_bytes_limit = 204800,    -- 显式传参的上限
    },
  },
})
```

非法值(非数字 / <= 0)回落到内置默认,`default > limit` 时夹到 limit。

### 9: 负数 offset = 取尾部

```lua
offset = -20  -- 最后 20 条(截断窗口之外最常被需要的那段)
```

`offset` 为负数时从末尾倒数;`search` 时倒数的是**匹配结果**。响应回显
**解析后的** `offset`(0-based 正数),模型据此继续分页。

## 设计决策

1. **丢弃 bookkeeping 条目而不是标注它们。** `limit` 是名额、字节是预算,
   空条目两头都占;它们对模型没有任何信息量。相反 `error` / `notice`
   承载"上一次失败""换过 api_key"这类事实,丢掉会让模型误解历史。
2. **只回填工具名,不回填 arguments。** 一条 `read_file` 的 arguments 可能有
   几百字节,而模型真正缺的信息是"这一步调了什么工具"。
3. **两套编号同时暴露,而不是合并成一套。** `index` 是稳定定位(可以跨调用
   对照),`offset` 是分页游标(会随 `search` 变化)。合并任意一套都会在
   另一种场景下失效。
4. **截断提示给精确预算而不是形容词。** 模型无法从"请调大"推断出该传多少,
   来回试探既烧 token 又可能死循环。
5. **负数 offset 修正而不是拒绝。** 负数传参是**明确的意图**(取最近几轮),
   静默 clamp 成 0 会给出语义相反的结果,属于隐患。

## 风险 / 未决问题

- `total` 语义从"原始条目数"变成"对话条目数"。`limit` 名额随之变化,
  属期望内的行为修正,需在 docs 里写明。
- 复用 `search_messages()` 会引入对 `chat.sessions.messages` 的依赖;
  该函数每次全表扫描,量级与现有实现相同(无性能回归)。
- `required_bytes` 是估算(含 note 自身长度),可能比真正够用的值大一点点,
  属于安全的过估。
- 负数 `offset` 与 `limit` 的组合需要文档写清:`offset=-5, limit=2` 表示
  "从倒数第 5 条开始取 2 条"。

## 测试要点

- 过滤:`on_complete` 标记不出现在 `messages`,`total` 不含它
- 保留:`error` / `notice` 条目带 `kind` 返回
- 工具:`assistant.tool_calls` 只含名字;`tool` 消息带 `tool` 名;无
  `tool_call_state` 的旧缓存不报错
- 分页:`next_message_index` = 下一条的全局 index;`required_bytes`
  重试后能整条读取
- 搜索:只命中 `reasoning_content` 的消息也返回;`total_matched` 语义不变
- 上限:`limit=300` → 200
- config:`default_max_bytes` / `max_bytes_limit` 生效;非法值回落
- 尾部:`offset=-2` 返回最后 2 条;`offset=-999` 从 0 开始
- 形状:无消息 / offset 越界都返回 JSON,含 `note`

