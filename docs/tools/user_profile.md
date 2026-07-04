---
layout: default
title: user_profile
parent: Tools
nav_order: 45
---

# user_profile

Manage user profiles (人物画像) for personalized assistance.

User profiles are stored as markdown files and contain information about users such as their preferences, skills, background, and working habits.

---

## Usage

```
@user_profile action="get" user_id="alice"
```

---

## Parameters

| Parameter  | Type   | Description                                                                                             |
| ---------- | ------ | ------------------------------------------------------------------------------------------------------- |
| `action`   | string | Action to perform: `get`, `update`, `list`, or `delete` (default: `get`)                               |
| `user_id`  | string | User ID to look up or modify. Can be ANY user, not just the current user. Defaults to current user.    |
| `content`  | string | Profile content in markdown format (required for `update` action)                                       |

---

## Actions

### get

Read a user profile. If no `user_id` is provided, reads the current user's profile.

```
@user_profile action="get"
@user_profile action="get" user_id="alice"
```

### update

Create or update a user profile. The `content` parameter should be in markdown format.

```
@user_profile action="update" user_id="alice" content="# User Profile: alice\n\n..."
```

### list

List all available user profiles.

```
@user_profile action="list"
```

### delete

Delete a user profile by user ID.

```
@user_profile action="delete" user_id="temp-user"
```

---

## Profile Format

Profiles are stored as markdown files with the following structure:

```markdown
# User Profile: <id>

## Basic Info
- Name: ...
- Timezone: ...
- Language: ...

## Preferences
- Editor: ...
- Coding style: ...

## Skills
- Languages: ...
- Frameworks: ...

## Notes
- ...
```

---

## Notes

{: .info }

> - The LLM can look up ANY user's profile by passing their `user_id`, not just the current user
> - When a specific user is mentioned during conversation, the LLM proactively looks up their profile
> - The LLM also proactively updates user profiles when learning new information about any user
> - Use `action="list"` to discover all available profiles

