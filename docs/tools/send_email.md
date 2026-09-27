---
layout: default
title: send_email
parent: Tools
nav_order: 49
---

# send_email

Send an email using the system `mail` command.

The body is piped to stdin, equivalent to:

```
echo "body" | mail -s "subject" user@example.com
```

## Usage

```
@send_email to="<address(es)>" subject="<subject>" [body="<text>"] [cc="<address(es)>"] [bcc="<address(es)>"]
```

## Examples

- `@send_email to="user@example.com" subject="Hello" body="Hi there"` - Send a simple email
- `@send_email to="a@x.com,b@x.com" subject="Report" body="..."` - Send to multiple recipients
- `@send_email to="user@example.com" subject="FYI" body="..." cc="boss@example.com"` - With cc
- `@send_email to="user@example.com" subject="FYI" body="..." bcc="audit@example.com"` - With bcc

## Parameters

| Parameter | Type   | Description                                           |
| --------- | ------ | ----------------------------------------------------- |
| `to`      | string | **Required**. Recipient address(es), comma-separated  |
| `subject` | string | **Required**. Email subject                           |
| `body`    | string | Email body text, sent via stdin (default: empty)     |
| `cc`      | string | Cc address(es), comma-separated                      |
| `bcc`     | string | Bcc address(es), comma-separated                      |

## Notes

{: .info }
> - Requires the `mail` command to be installed (mailutils / bsd-mailx / s-nail)
> - Requires a mail transfer agent (sendmail / postfix) to be configured for delivery
> - Not available on Windows
> - Addresses are validated: option-like values (e.g. `-b`) are rejected
> - Arguments are passed as a list, never through a shell

