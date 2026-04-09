---
layout: default
title: Weixin
nav_order: 7
parent: Integrations
---
# Weixin (Personal WeChat) Integration

{: .no_toc }

## Table of contents
{: .no_toc .text-delta }
1. TOC
{:toc}

---

Weixin integration for personal WeChat accounts via QR code login.

## Features

- **QR Code Login**: Scan with WeChat to login
- **Auto Credential Caching**: Login credentials saved locally
- **Auto Reconnect**: Automatically reconnects on restart
- **Long Message Support**: Auto-chunking for messages > 2,048 characters

---

## Setup Guide

### 1. First-Time Login

Run the following Lua command in Neovim:

```vim
:lua require('chat.integrations.weixin').login()
```

A QR code will be displayed in a floating window.

{: .info }
> The QR code is generated via the OpenClaw WeChat Gateway.

### 2. Scan QR Code

- Open WeChat on your phone
- Scan the QR code
- Confirm login on your phone

{: .warning }
> Do not share the QR code with others to prevent unauthorized access.

### 3. Done!

Login credentials are automatically saved to:

```
stdpath('data')/chat-weixin-state.json
```

Subsequent restarts will auto-connect using saved credentials.

{: .highlight }
> You don't need to login again unless credentials expire or are cleared.

---

## Commands

| Command                                                | Description                  |
| ------------------------------------------------------ | ---------------------------- |
| `:lua require('chat.integrations.weixin').login()`     | Start QR code login          |
| `:lua require('chat.integrations.weixin').logout()`    | Logout and clear credentials |
| `:lua require('chat.integrations.weixin').get_state()` | Check connection status      |

---

## Technical Details

- **API**: OpenClaw WeChat Gateway
- **Authentication**: QR Code Login (auto-refresh)
- **Message Limit**: 2,048 characters (auto-chunking)
- **State Persistence**: `stdpath('data')/chat-weixin-state.json`
- **Polling**: Long-poll every 3 seconds

---

## Troubleshooting

### QR Code Not Displaying

**Symptom**: QR code window not appearing.

**Solution**:
1. Check if the floating window is created
2. Verify the gateway is accessible
3. Check Neovim logs for errors

### Login Failed

**Symptom**: QR code scan does not complete login.

**Solution**:
1. Ensure you confirm login on your phone
2. Check network connectivity
3. Try scanning again with a fresh QR code

### Connection Lost

**Symptom**: Messages not being received after restart.

**Solution**:
1. Check if credentials are saved
2. Run `:lua require('chat.integrations.weixin').get_state()` to check status
3. Re-login if credentials expired

---

## Security Notes

{: .warning }
> - Never share your QR code with others
> - Credentials are stored locally in `stdpath('data')`
> - Logout to clear credentials when switching devices
> - Use `:lua require('chat.integrations.weixin').logout()` to clear state

---

## Next Steps

- [Discord Integration](/docs/integrations/discord/) - Setup Discord bot
- [Telegram Integration](/docs/integrations/telegram/) - Setup Telegram bot
- [IM Integration Overview](/docs/integrations/im/) - All IM integrations
