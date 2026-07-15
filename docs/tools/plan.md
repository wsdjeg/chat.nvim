---
layout: default
title: plan
parent: Tools
nav_order: 13
---

# plan

Plan mode for creating, managing, and reviewing task plans with step-by-step tracking.

## Usage

```
@plan action="<action>" [parameters]
```

## Actions

| Action   | Description                                   |
| -------- | --------------------------------------------- |
| `create` | Create new plan with title and optional steps |
| `show`   | Show plan details by ID                       |
| `list`   | List plans in current session (optional status filter, use `include_project` for same-dir plans) |
| `add`    | Add step to existing plan                     |
| `next`   | Start next pending step                       |
| `done`   | Mark current/completed step as done           |
| `pause`  | Pause an in-progress plan                     |
| `resume` | Resume a paused plan                          |
| `review` | Review completed plan with summary            |
| `delete` | Delete a plan                                 |

## Examples

1. **Create a new plan:**

   ```
   @plan action="create" title="Implement feature X" steps=["Design API", "Write code", "Test"]
   ```

2. **List all plans:**

   ```
   @plan action="list"
   ```

3. **Start next step:**

   ```
   @plan action="next" plan_id="plan-20250110-1234"
   ```

4. **Complete a step:**

   ```
   @plan action="done" plan_id="plan-20250110-1234" step_id=1
   ```

## Parameters

| Parameter      | Type    | Description                                                                                |
| -------------- | ------- | ------------------------------------------------------------------------------------------ |
| `action`       | string  | **Required**. Plan action to perform (create, show, list, add, next, done, review, delete) |
| `title`        | string  | Plan title (required for create action)                                                    |
| `steps`        | array   | Initial steps array (optional for create action)                                           |
| `plan_id`      | string  | Plan ID (required for show, add, next, done, review, delete)                               |
| `step_content` | string  | Step content (required for add action)                                                     |
| `step_id`      | integer | Step ID (required for done action, auto-detected if not provided)                          |
| `notes`        | string  | Notes for step completion (optional for done action)                                       |
| `status`       | string  | Filter by status for list action (pending, in_progress, completed)                         |
| `include_project` | boolean | Include plans from same project dir when listing (default: false, session only)       |
| `summary`      | string  | Plan summary (for review action)                                                           |
| `lessons`      | array   | Lessons learned (for review action)                                                        |

