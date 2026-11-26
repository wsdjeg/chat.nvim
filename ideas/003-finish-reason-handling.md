# 003 - finish_reason 处理统一与兜底

**状态:** partial — 第 1 层(兜底)已落地,第 2/3 层待做

## 已落地(第 1 层兜底)

`openai.lua` / `anthropic.lua` / `gemini.lua` 的 `on_exit` 都已是
「tool 类 reason 走工具循环,其余一律走完成收尾」:

```lua
-- openai.lua
if reason == 'stop' then ... elseif reason == 'tool_calls' then ...
elseif reason == 'length' and code == 0 and signal == 0 then
  -- 截断自动续写
elseif code == 0 and signal == 0 and not rotating then
  -- 其它任何 reason(含 nil):把已流出的内容收尾,不丢
end
```

- `length` 走自动续写(见 `lua/chat/sessions/continue.lua`),截断不再丢上下文
- `content_filter` / `refusal` / `recency` / `nil` 等未知 reason 都落到收尾分支,
  内容进历史
- 收尾分支带 `not rotating` 与前一条 error 判定,避免和换 key / 重试抢同一次结束

commit: `dd0bcd1`(keep responses finished with unknown reasons in history)、
`f211a37`(auto-continue truncated responses)

## 未落地(第 2 + 第 3 层)

### 第 2 层:枚举规范化

现在 `on_exit` 仍在比较 provider 原生字符串:anthropic 判
`end_turn or 'stop'`,openai 判 `'tool_calls'`(旧 API 的 `function_call`
落进兜底收尾分支,等于「该调工具却按正常结束处理」)。统一枚举还没做:

```
stop | tool_calls | length | content_filter
```

待补映射:

- anthropic:`end_turn`→`stop`、`tool_use`→`tool_calls`、
  `max_tokens`→`length`、`refusal`→`content_filter`
- openai:`function_call`→`tool_calls`
- gemini:已做(`max_tokens`→`length`、`safety`→`content_filter`)

### 第 3 层:截断/过滤提示走 metadata

目前 finish_reason 只用于控制流,不进消息对象,UI 无法提示「被截断 / 被过滤」。
待做:

```lua
-- progress.lua on_progress_done(jobid, opts)
if opts and opts.finish_reason then
  message.finish_reason = opts.finish_reason
end
```

UI 层据此显示提示,**不写进 content**(否则下一轮会当成真的助手回复发回上游)。

## 设计决策(仍然有效)

1. **fallback 语义是「默认完成」而非「默认 tool」。** 漏收尾 → 丢内容,
   漏循环 → 至多多一次空转,而 tool 分支内部本就有 no-data 兜底。
2. **finish_reason 与「是否工具循环」解耦。** 控制流看数据事实(tool_calls
   是否存在),finish_reason 只承担「截断/过滤」提示。
3. **提示走 metadata,不走 content 文本。**

## 风险 / 未决问题

- 第 2 层只是把字符串比较集中化,不改变行为;真正需要判断的是
  `function_call` 现在被当成正常收尾,是否要改成走工具循环(旧 API 兼容,
  目前没有 provider 触发,优先级低)。
- `content_filter` / `refusal` 时内容可能为空,收尾不 append 任何东西,
  用户看到的是「什么都没有」。第 3 层的 UI 提示正是补这个缺口。

## 测试要点

- 第 1 层已覆盖:`test/protocol_stream_spec.lua` 有 `content_filter`、
  `refusal`、`length`、`nil` reason 的用例,断言内容仍进历史
- 第 2 层落地后需补:anthropic `max_tokens` / `end_turn` / `tool_use` 映射,
  openai `function_call` 走工具循环
- 第 3 层落地后需补:`on_progress_done(..., finish_reason='length')` 后
  消息对象带该字段,且 `content` 未被追加任何提示文本
- 照规矩 `config.setup({ storage_dir = temp })` 起隔离环境

## 落地范围(剩余)

- `lua/chat/protocol/{openai,anthropic}.lua`:reason 映射集中到一处
- `lua/chat/sessions/progress.lua`:`finish_reason` 透传到消息 metadata
- UI 展示层(`lua/chat/windows/` 或 formatter):按 metadata 显示提示

