---
layout: default
title: make
parent: Tools
nav_order: 3
---

# make

{: .no_toc }

Run make targets and return results.

## Usage

```
@make [target="<target>"] [args=["..."]] [directory="<dir>"]
```

## Examples

- `@make` - Run default target
- `@make target="test"` - Run make test
- `@make target="build"` - Run make build
- `@make target="test" args=["-j4"]` - Run with options
- `@make target="build" args=["-j4", "VERBOSE=1"]` - Build with 4 jobs and verbose
- `@make directory="./subproject"` - Run in subdirectory
- `@make target="clean" args=["all"]` - Clean and rebuild

## Parameters

| Parameter   | Type     | Description                                                      |
| ----------- | -------- | ---------------------------------------------------------------- |
| `target`    | string   | Make target to run (e.g., "test", "build", "clean")              |
| `args`      | array    | Additional arguments for make (e.g., ["-j4", "VERBOSE=1"])       |
| `directory` | string   | Directory to run make in (default: current working directory)    |

## Output

Returns make command output with exit code and status:
- Exit code 0 indicates success
- Exit code non-zero indicates failure
- Output includes stdout and stderr

## Notes

{: .info }
> - Requires make to be installed and available in PATH
> - Directory must be within allowed_path configuration
> - Common targets: build, test, clean, install, all
> - Use args for make options like -j (jobs), -n (dry-run), VERBOSE=1

