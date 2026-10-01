# 003 - finish_reason 处理统一与兜底

**状态:** draft

## 动机

流式响应里 `finish_reason`(Anthropic 叫 `stop_reason`,Gemini 叫
`finishReason`)目前被各 protocol 的 `on_exit` 用来**决定控制流**,但匹配
得很窄。控制流本该只由「这次到底有没有 tool_calls」决定,却散落在了
finish_reason 字符串的比较上,导致非 `stop` / 非 tool 类的结束原因被静默
丢弃。

典型坏例子:`length`(= max_tokens 截断)。内容已经流式显示在结果窗口里,
但 `on_progress_done` 没有被调用 → 累积的 `progress_messages` 不落盘、不
进消息历史,下一轮请求也拿不到这段上下文。

## 现状(问题矩阵)

| 文件 | 匹配分支 | 漏掉的 finish_reason |
|------|---------|---------------------|
| openai   | `stop` / `tool_calls` | `length`、`content_filter`、`function_call`、`nil` |
| anthropic| `end_turn`→`stop` / `tool_use` | `max_tokens`、`refusal`、`nil` |
| gemini   | 只处理 `stop` | `length`、`content_filter`(已映射但没人接)|

gemini 已经做了映射(`max_tokens`→`length`、`safety`→`content_filter`),
但 `on_exit` 里没有对应分支去接,等于白映射了。

## 核心洞察

**决定「要不要走工具循环」的不是 finish_reason 字符串,而是「有没有真的
收到 tool_calls 数据」。** `on_progress_tool_call_done` 内部已经做了
no-data 兜底(收到 tool 类 reason 却没数据时,报错 + `on_progress_done({tool_calls={}})`
+ `on_complete`),所以把 tool 判断交给它是安全的。

## 方案(三层,1→2 建议一起做,3 单独做)

### 第 1 层:兜底修复(必须)

把 `on_exit` 改成「只有 tool 类 reason 走工具循环,其余一律走完成收尾」,
保证任何结束原因都不丢内容:

```lua
-- openai.lua on_exit
local reason = sessions.get_progress_finish_reason(id)
if reason == 'tool_calls' or reason == 'function_call' then
  sessions.on_progress_tool_call_done(id)  -- 内部已有 no-data 兜底
else
  -- stop / length / content_filter / nil 都走到这里,内容不丢
  sessions.on_progress_done(id, { finish_reason = reason })
  sessions.on_complete(session, id)
end
```

```lua
-- anthropic.lua on_exit
if reason == 'tool_use' then
  sessions.on_progress_tool_call_done(id)
else
  sessions.on_progress_done(id, { finish_reason = reason })
  sessions.on_complete(session, id)
end
```

```lua
-- gemini.lua on_exit(现在只有 stop 分支,漏了 length/content_filter)
if reason == 'tool_calls' then
  sessions.on_progress_tool_call_done(id)
else
  sessions.on_progress_done(id, { finish_reason = reason })
  sessions.on_complete(session, id)
end
```

### 第 2 层:枚举规范化(建议)

在 protocol 层统一映射到一套标准枚举,`on_exit` 只看标准值:

```
stop           -- 正常结束
tool_calls     -- 调用工具
length         -- max_tokens 截断
content_filter -- 内容安全过滤
```

补齐映射即可,gemini 已做,anthropic / openai 跟进:

- anthropic:`end_turn`→`stop`、`tool_use`→`tool_calls`、
  `max_tokens`→`length`、`refusal`→`content_filter`
- openai:`function_call`→`tool_calls`(旧 API 兼容)

### 第 3 层:增强(可选,独立 PR)

截断 / 过滤时给用户反馈,但**不污染 content 文本**,而是挂到消息 metadata:

```lua
-- progress.lua on_progress_done 里
if opts and opts.finish_reason then
  message.finish_reason = opts.finish_reason
end
```

UI 层根据 `finish_reason` 决定要不要显示
"(response truncated / filtered)" 之类的提示。

## 设计决策

1. **fallback 语义是「默认完成」而非「默认 tool」。** 只有明确的 tool 类
   reason 才继续循环,其余(含 `nil`)一律收尾。理由:漏收尾 → 丢内容,
   漏循环 → 至多多一次空转,tool 分支又有 no-data 兜底,代价不对称。

2. **finish_reason 与「是否工具循环」解耦。** 前者是流元数据,后者是
   数据事实。控制流交给数据事实(tool_calls 是否存在),finish_reason 只
   用来提示用户截断/过滤,不再承担流控职责。

3. **提示走 metadata,不走 content 文本。** 往 `message.content` 里塞
   "(truncated)" 会污染上下文(下一轮会把它当真的助手回复发回去)。挂到
   独立字段,UI 层选择性展示。

4. **`nil` reason 按 `stop` 兜底。** 非流式返回、连接在 finish_reason 前
   中断等情况可能拿不到 reason,此时仍应完成收尾,避免丢已流出的内容。

## 风险 / 未决问题

- **`content_filter` 时内容可能为空甚至无 content。** 走到完成收尾没问题
  (有 reasoning 或 tool_calls 才 append),但 UI 是否要给明确提示待定。
- **`on_progress_done` 增加 `finish_reason` 参数会影响现有调用点。** 现有
  调用处不传即可(参数可选),需确认 `on_progress_tool_call_done` 内部那两条
  `on_progress_done` / `on_complete` 路径与本方案不冲突。
- **`length` 截断后是否自动续写下一段?** 不在本次范围,只保证不丢 + 提示。
  若要做「截断自动续写」需另起 idea(涉及把已生成内容并入新请求)。
- **各 provider 的 reason 全集未穷尽。** OpenAI 未来可能新增 reason 值。
  用「除 tool 外默认完成」的 fallback 天然抗新增值,这正是第 1 层的价值。

## 测试要点

- openai:`length` reason → 内容仍 `append_message`、`on_complete` 被调用
  (不被丢弃)
- anthropic:`tool_use` → 走工具循环;`max_tokens` → 完成收尾
- gemini:`length` / `content_filter` → 完成收尾(补上被漏的分支)
- `nil` reason(non-stream 或无 finish_reason)→ 完成收尾,已有流式内容不丢
- `tool_calls` reason 但无数据 → 沿用现有 no-data 兜底(报错 + 收尾)
- 回归:正常 `stop` / tool 循环行为不变
- 照规矩 `config.setup({ storage_dir = temp })` 起隔离环境

## 落地范围

改动集中在三个 protocol 文件(`openai.lua` / `anthropic.lua` / `gemini.lua`)
+ `sessions/progress.lua`(`on_progress_done` 加可选 `finish_reason` 透传)。
协议层之外无改动。
