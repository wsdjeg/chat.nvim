---
layout: default
title: Weixin Integration
parent: IM Integration
nav_order: 7
---

<!-- prettier-ignore-start -->
# Weixin (Personal WeChat) Integration
{: .no_toc }
## Table of contents
{: .no_toc }
<!-- prettier-ignore-end -->

<!-- prettier-ignore -->
- content
{:toc}

---

Weixin integration for personal WeChat accounts via QR code login.

## Features

- **QR Code Login**: Scan with WeChat to login
- **Auto Credential Caching**: Login credentials saved locally
- **Auto Reconnect**: Automatically reconnects on restart
- **Long Message Support**: Auto-chunking for messages > 2,048 characters
- **Voice Messages**: Answered from WeChat's speech-to-text transcript; falls
  back to a `[voice]` placeholder when no transcript is available

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
{storage_dir}/integration/weixin.json
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

## Voice Messages

The plugin does **not** run speech recognition itself. It uses the transcript
that WeChat's server-side ASR attaches to the `voice_item`:

```json
{
  "type": 3,
  "voice_item": {
    "text": "我下午三点到。",
    "encode_type": 7,
    "playtime": 1426,
    "media": {
      "encrypt_query_param": "...",
      "aes_key": "..."
    }
  }
}
```

Behaviour:

| `voice_item.text` | What the model receives |
| ----------------- | ----------------------- |
| non-empty         | the transcript as-is    |
| empty / missing   | `[voice]` placeholder   |

The placeholder keeps the message deliverable. Without it the item contributes
no text, the inbound message is dropped, and the bot silently ignores the voice
note.

{: .note }

> `encode_type` / `playtime` / `sample_rate` and the CDN media reference
> (`media.encrypt_query_param`, `media.aes_key`, `media.full_url`) are parsed
> and kept on the item, so a downstream ASR step can be added later.

---

## Technical Details

- **API**: OpenClaw WeChat Gateway
- **Authentication**: QR Code Login (auto-refresh)
- **Message Limit**: 2,048 characters (auto-chunking)
- **Media Parsing**: CDN references are read from `<type>_item.media`
  (`encrypt_query_param`, `aes_key`, `full_url`); legacy payloads that put
  these fields directly on the sub-item are still accepted. Inbound images
  prefer the hex `image_item.aeskey` when present.
- **Voice**: transcribed by WeChat; `[voice]` placeholder when the transcript
  is empty
- **Send Retry**: failed messages are retried once; a second failure is logged as error
- **State Persistence**: `{storage_dir}/integration/weixin.json`
- **Polling**: Long-poll every 3 seconds

---

## Troubleshooting

### Voice Message Gets No Reply

**Symptom**: Text messages are answered, voice messages are not.

**Cause**: WeChat returned an empty `voice_item.text`. The gateway only fills
the transcript when its own ASR succeeds; short notes, background noise, or
voice-to-text disabled on the sender's client all produce `""`.

**Check the raw payload** in the debug log — look for
`parse raw message: ...` and inspect the `voice_item`:

```json
"voice_item": { "text": "", "encode_type": 7, "playtime": 1426, ... }
```

**Solution**:

1. Upgrade to a version that emits the `[voice]` placeholder — the message is
   then still delivered to the model.
2. Alternatively send the note again as text; the transcript is produced by
   WeChat, not by this plugin, so it cannot be forced from the Neovim side.

### Voice Note Transcription Missing

**Symptom**: The bot sees `[voice]` instead of the spoken content.

**Cause**: WeChat did not transcribe the audio for this message.

**Solution**: There is no plugin-side workaround yet. Running a real ASR step
would require downloading and decrypting the audio (AES-128-ECB over the CDN
media reference), which is not implemented.

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
> - Credentials are stored locally in `{storage_dir}/integration/weixin.json`
> - Logout to clear credentials when switching devices
> - Use `:lua require('chat.integrations.weixin').logout()` to clear state

---

---

## Next Steps

- [Discord Integration](./discord/) - Setup Discord bot
- [Telegram Integration](./telegram/) - Setup Telegram bot
- [IM Integration Overview](./) - All IM integrations

