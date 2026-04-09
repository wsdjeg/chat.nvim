---
layout: default
title: git_commit
parent: Tools
nav_order: 19
---

# git_commit

{: .no_toc }

Create a git commit with the specified message.

## Usage

```
@git_commit message="<message>" [allow_empty=true] [amend=true]
```

## Examples

- `@git_commit message="feat: add user authentication"` - Create commit
- `@git_commit message="fix: resolve login issue"` - Bug fix commit
- `@git_commit message="docs: update README" allow_empty=true` - Allow empty commit
- `@git_commit message="WIP" amend=true` - Amend previous commit

## Parameters

| Parameter     | Type    | Description                          |
| ------------- | ------- | ------------------------------------ |
| `message`     | string  | **Required**. Commit message         |
| `allow_empty` | boolean | Allow empty commit (optional)        |
| `amend`       | boolean | Amend previous commit (optional)     |

## Recommended Commit Message Format

| Type       | Description              | Example                        |
| ---------- | ------------------------ | ------------------------------ |
| `feat`     | New feature              | `feat: add user authentication`|
| `fix`      | Bug fix                  | `fix: resolve login issue`     |
| `docs`     | Documentation changes    | `docs: update README`          |
| `refactor` | Code refactoring         | `refactor: simplify API`       |
| `test`     | Adding tests             | `test: add unit tests`         |
| `chore`    | Maintenance tasks        | `chore: update dependencies`   |

## Notes

{: .info }
> - Requires git to be installed and in PATH
> - Requires changes to be staged first (use git_add)
> - Commit message is required
> - Use `allow_empty=true` for commits without changes
> - Use `amend=true` to modify the previous commit
> - Follow [Conventional Commits](https://www.conventionalcommits.org/) specification

