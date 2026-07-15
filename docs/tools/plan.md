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

| Action           | Description                                                        |
| ---------------- | ------------------------------------------------------------------ |
| `create`         | Create new plan with title and optional steps                      |
| `show`           | Show plan details by ID (includes review info)                     |
| `list`           | List plans in current session (optional status filter, use `include_project` for same-dir plans) |
| `add`            | Add step to existing plan                                          |
| `next`           | Start next pending step                                            |
| `done`           | Mark current/completed step as done                                |
| `cancel_step`    | Cancel a step (mark as cancelled)                                  |
| `delete_step`    | Delete a step from plan                                            |
| `update_step`    | Update step content                                                |
| `reorder_steps`  | Reorder steps by providing ordered step IDs                        |
| `pause`          | Pause an in-progress plan                                          |
| `resume`         | Resume a paused plan                                               |
| `review`         | Review a completed or abandoned plan with summary                  |
| `update_title`   | Update plan title                                                  |
| `cancel`         | Abandon a plan (mark as abandoned)                                 |
| `reopen`         | Reopen a completed or abandoned plan                               |
| `delete`         | Delete a plan                                                      |

## Plan Status Flow

```
pending → in_progress → completed
              ↕              ↕
           paused        reopened
              ↓
          abandoned → reopened
```

## Step Status

| Status        | Icon | Description                    |
| ------------- | ---- | ------------------------------ |
| `pending`     | ⬜   | Not yet started                |
| `in_progress` | ⏳   | Currently being worked on      |
| `completed`   | ✅   | Finished                       |
| `cancelled`   | ❌   | Cancelled (skipped)            |

## Examples

1. **Create a new plan:**

   ```
   @plan action="create" title="Implement feature X" steps=["Design API", "Write code", "Test"]
   ```

2. **List all plans:**

   ```
   @plan action="list"
   ```

3. **List plans across the project (same working dir):**

   ```
   @plan action="list" include_project=true
   ```

4. **Start next step:**

   ```
   @plan action="next" plan_id="plan-20250110-1234"
   ```

5. **Complete a step:**

   ```
   @plan action="done" plan_id="plan-20250110-1234" step_id=1
   ```

6. **Cancel a step:**

   ```
   @plan action="cancel_step" plan_id="plan-20250110-1234" step_id=2 notes="No longer needed"
   ```

7. **Reorder steps:**

   ```
   @plan action="reorder_steps" plan_id="plan-20250110-1234" step_ids=[3, 1, 2]
   ```

8. **Pause a plan with reason:**

   ```
   @plan action="pause" plan_id="plan-20250110-1234" pause_reason="Waiting for API"
   ```

9. **Abandon a plan:**

   ```
   @plan action="cancel" plan_id="plan-20250110-1234" notes="Requirements changed"
   ```

10. **Reopen a completed plan:**

    ```
    @plan action="reopen" plan_id="plan-20250110-1234"
    ```

11. **Review a completed plan:**

    ```
    @plan action="review" plan_id="plan-20250110-1234" summary="Feature implemented" lessons=["Lesson 1"]
    ```

## Parameters

| Parameter         | Type    | Description                                                                                |
| ----------------- | ------- | ------------------------------------------------------------------------------------------ |
| `action`          | string  | **Required**. Plan action to perform                                                       |
| `title`           | string  | Plan title (for create, update_title)                                                      |
| `steps`           | array   | Initial steps array (for create)                                                           |
| `plan_id`         | string  | Plan ID (required for most actions)                                                        |
| `step_content`    | string  | Step content (for add, update_step)                                                        |
| `step_id`         | integer | Step ID (for done, cancel_step, delete_step, update_step)                                  |
| `step_ids`        | array   | Ordered list of step IDs (for reorder_steps)                                               |
| `notes`           | string  | Notes for step completion, or reason for cancel/cancel_step                                |
| `pause_reason`    | string  | Reason for pausing a plan (for pause action)                                               |
| `status`          | string  | Filter by status for list action                                                           |
| `include_project` | boolean | Include plans from same project dir when listing (default: false, session only)            |
| `summary`         | string  | Plan summary (for review)                                                                  |
| `lessons`         | array   | Lessons learned (for review)                                                               |
| `issues`          | array   | Issues encountered (for review)                                                            |

