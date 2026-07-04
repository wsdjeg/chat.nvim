---
layout: default
title: schedule_task
parent: Tools
nav_order: 46
---

# schedule_task

Schedule a task to be executed at a future time. Tasks persist across Neovim restarts (stored on disk).

When a scheduled task fires, a message is injected into the target session's message queue, and the LLM will process it as if the user sent it.

---

## Usage

```
@schedule_task action="create" message="Check server status" delay_seconds=3600
```

---

## Parameters

| Parameter        | Type   | Description                                                                        |
| ---------------- | ------ | ---------------------------------------------------------------------------------- |
| `action`         | string | Action to perform: `create`, `list`, or `cancel` (default: `create`)              |
| `message`        | string | Message to send when the task triggers (required for `create`)                     |
| `delay_seconds`  | number | Delay in seconds before the task triggers (one-time task). Max 2592000 (30 days)   |
| `trigger_at`     | number | Unix timestamp when the task should trigger (one-time task, alternative to delay)   |
| `interval`       | number | Interval in seconds for periodic tasks (e.g., 86400 = daily, 3600 = hourly)        |
| `repeat_count`   | number | Maximum repetitions for periodic tasks (nil = unlimited)                            |
| `task_id`        | string | Task ID to cancel (required for `cancel` action)                                    |

---

## Actions

### create

Create a new scheduled task.

**One-time task with delay:**

```
@schedule_task action="create" message="Visit https://example.com and summarize" delay_seconds=3600
```

**One-time task at specific time:**

```
@schedule_task action="create" message="Remind me about the meeting" trigger_at=1717200000
```

**Periodic task (every 30 minutes):**

```
@schedule_task action="create" message="Check server status" interval=1800
```

**Periodic task with max repeats:**

```
@schedule_task action="create" message="Daily summary" interval=86400 repeat_count=7
```

### list

List all scheduled tasks.

```
@schedule_task action="list"
```

### cancel

Cancel a scheduled task by ID.

```
@schedule_task action="cancel" task_id="1717200000-12345"
```

---

## Notes

{: .info }

> - `delay_seconds` and `trigger_at` are mutually exclusive for one-time tasks
> - `interval` creates a recurring task (use `repeat_count` to limit repetitions)
> - Tasks survive Neovim restarts (stored on disk)
> - Maximum delay: 30 days (2592000 seconds)
> - When a task fires, the message is processed by the LLM as if the user sent it

