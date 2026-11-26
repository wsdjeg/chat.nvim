# Lark 集成增强方案书

- **状态**: partial — Phase 1–3 已落地;Phase 4 与两个管理入口待做
- **日期**: 2026-11-07(更新 2026-11-26)
- **影响模块**: `lua/chat/integrations/lark.lua` 及 `lua/chat/integrations/lark/*`
- **兼容性原则**: 只增不改,旧集成 0 行改动,现有测试原样通过

---

## 1. 已落地(P1–P3)

### Phase 1 — 权限层 (ACL)

| 内容 | 位置 |
|------|------|
| `is_allowed()` / `is_admin()` / `acl_mode()` | `lua/chat/integrations/lark/acl.lua` |
| 身份归一化(open_id / 邮箱 / 手机号 / `us_` `on_` 显式拒绝) | `lua/chat/integrations/lark/identity.lua` |
| `connect()` 时解析 ACL + 失败逐条点名(fail closed) | `acl.resolve_acl()`(`poll.lua:796`) |
| `state.identities` + `identities_hash` 缓存失效 | `lua/chat/integrations/lark/state.lua` |
| 最近发言人缓存(`get_recent_senders()`) | `acl.record_sender()` / `state.recent_senders` |
| 群内 `/allow` `/deny` `/acl`(admin only,需 @ 机器人) | `acl.parse_acl_command()` / `acl.handle_acl_command()` |
| p2p 独立默认拒绝策略(`is_p2p_allowed()`) | `acl.is_p2p_allowed()` |

测试:`test/lark_identity_spec.lua`、`test/lark_spec.lua`、`test/lark_poll_spec.lua`。

### Phase 2 — 多路绑定 (bindings)

| 内容 | 位置 |
|------|------|
| `containers[chat_id] = { chat_type, peer, session, last_seen_time }` | `container.lua` / `state.lua` |
| `get_binding` / `set_binding` / `get_bound_sessions` / `get_chat_bindings` | `container.lua` |
| 共享层 `chat.bridge` 统一问「这个 session 绑了哪些 chat」 | `lua/chat/bridge.lua` |
| 消息带 `chat_id` / `chat_type`,按 chat 路由 session | `poll.lua` callback |
| 回复按 session 反查 chat(`send_message(content, session)`) | `send.lua` `send_target()` |
| `:Chat bridge lark` 主绑定语义保持(平台级 set_session 同步主 binding) | `container.lua` |
| 群内 `/session` 走 `set_binding(chat_id, sid)` | `container.lua` + 共享层 |
| stale binding 清理(`session_is_stale`) | `container.lua` `drop_stale_binding()` |
| 每个 chat 独立 workspace + `allowed_path` 重注册 | `container.lua` `ensure_workspace()` |

测试:`test/lark_container_spec.lua`(含 roundtrip 与契约)。

### Phase 3 — P2P 私聊

| 内容 | 位置 |
|------|------|
| 从本侧发起私聊:`POST messages` → 取 `message_id` → `GET messages/{id}` 拿 `chat_id` | `lark/p2p.lua` `create_p2p()` |
| connect 时按允许列表自动开通(`provision_p2p()`) | `lark/p2p.lua` |
| p2p 免 @(`need_mention = ctr.chat_type ~= 'p2p'`) | `lark/poll.lua` |
| p2p sender 校验(容器 peer 之外的人一律忽略) | `lark/poll.lua` |
| p2p 回复走 `receive_id_type=open_id`,不依赖 `oc_` | `lark/send.lua` `send_target()` |

测试:`test/lark_p2p_spec.lua`、`test/lark_send_spec.lua`。

---

## 2. 待做

### 2.1 ACL 管理 picker(Neovim 侧)

现状只有群内命令。管理员得在群里 @ 机器人才配得动 ACL;而 `recent_senders`
缓存已经在攒数据(`get_recent_senders()` 按 `last_seen` 倒序),缺的只是一个
入口。

设计:

- picker 列出 `get_recent_senders()`,每项显示 `name`(昵称,有则显示)+ `open_id`
  + 来源 `chat_id` + 最后发言时间
- action 三个:`allow` / `deny` / `bind session`(第三个复用 `set_binding`)
- 写入时直接落 **open_id** 形式(缓存里本来就是 open_id),**不经过**
  `identity.resolve()` —— 邮箱/手机号解析只是手写配置时的便利
- 写 config 还是写 state:`allow` / `deny` 走 state 运行时表(与群内命令一致,
  不重启即生效);要改配置文件由用户自己改

不做的:不要在 picker 里编辑 `config`。运行时表 + 配置文件合并已在
`acl.get_acl()` 里实现,两套写入路径会打架。

### 2.2 绑定管理 picker

列出 `bindings`(即 `state.containers` 里有 `session` 的项)+ 最近活跃 chat,
选中后绑到**当前窗口 session**。

- 数据:`container.get_containers()`(已按 id 排序)+ `get_chat_bindings(session)`
- 展示:`chat_type`(group / p2p)、`peer`(p2p 才有)、当前绑的 session
- 解绑 = `set_binding(chat_id, nil)`,与 `bridge.unbind` 的语义一致

`lua/picker/sources/chat_integrations.lua` 现在只**展示**已绑定的 session
(`chat_bridge.bound_sessions()`),不能改绑 —— 这是缺口。

### 2.3 reply 定向回复

现在所有回复都是 `POST /im/v1/messages`(新消息),群聊里看不到「回复某条」的
引用关系。改成:

```
POST /im/v1/messages/{message_id}/reply
```

- `message_id` 已经在 callback 里(`poll.lua` 传了 `msg.message_id`),数据链路
  不缺;缺的是把它带进发送队列
- `send_message(content, session)` 目前第二参只有 session,需要再带上
  `message_id`(第三参可选,旧调用点不传即走原路径)
- 入队项变成 `{ content, chat_id, message_id }`,`send_target()` 旁边多一条
  「有 message_id 就发 reply,否则发 messages」的分支
- 失败回退:reply 接口对已撤回的消息会报错,此时退回 `POST /messages`,
  否则整条回复丢失
- 可选 `reply_in_thread`:话题群里回复挂在话题下,不在主群刷屏

### 2.4 Phase 4 — WebSocket 长连接事件订阅

飞书支持长连接模式事件订阅(`im.message.receive_v1`),不需要公网 IP。

- **收益**:秒级响应(现在 `poll_interval = 3000`ms)、p2p 天然可达
- **成本**:要自己实现 WebSocket 客户端(curl 干不了),工程量大
- **风险**:最高,且前三阶段用轮询已能满足需求

独立模块,共享层与旧集成 0 行改动。优先级最低,如无强需求可以一直不做。

---

## 3. 设计决策(仍然有效,供待做部分参考)

1. **隔离粒度是 chat_id,不是 platform。** 群 A / 群 B / 私聊各一个 session,
   `current_session()` 保持平台级主绑定,旧调用方零感知。
2. **权限比对一律在 open_id 空间。** `us_xxx` 与 open_id 永远不相等,所以
   要么用 open_id,要么用邮箱/手机号在 connect 时解析一次;`us_` 直连拒绝。
3. **fail closed。** admins / whitelist 解析失败视为不存在,绝不放宽权限;
   blacklist 解析失败只能放行 + warn(无法识别该人)。
4. **计算在轮询内,不额外开请求。** ACL 判定是纯字符串集合运算;身份解析只在
   config 变化时一次。

## 4. 风险

- **state 兼容**:`load_state()` 已对所有新字段做 nil 守卫,旧 `lark.json` 正常
  加载;新增字段继续遵守这条。
- **reply 回退**:reply 失败必须回退到普通发送,不能因为「想挂引用」丢消息。
- **picker 写入与配置文件冲突**:运行时表优先于 config 合并,两者都在
  `acl.get_acl()` 里,不要在 picker 里改 config。

## 5. 待办清单

- [x] Phase 1: ACL 校验 + 身份归一化 + 最近发言人缓存
- [x] Phase 1: 群内 `/allow` `/deny` `/acl`
- [ ] Phase 1: ACL picker(allow / deny / bind session)
- [x] Phase 2: bindings 数据结构 + 持久化 + roundtrip 测试
- [x] Phase 2: `get_binding` / `set_binding` / `get_bound_sessions`
- [x] Phase 2: 共享层 nil 守卫 + `:Chat bridge` 语义保持
- [ ] Phase 2: 绑定管理 picker
- [ ] Phase 2: reply 定向回复(`/im/v1/messages/{id}/reply`)+ 失败回退
- [x] Phase 3: P2P 发现 + 开通 + 免 @ + 独立 workspace
- [ ] Phase 4: WebSocket 客户端(可选)
- [x] 每个 Phase 完成后跑 `make test`,契约 spec 全绿

