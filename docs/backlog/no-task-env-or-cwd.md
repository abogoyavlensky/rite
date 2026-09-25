# Tasks cannot set environment variables or a working directory for their steps

**Status: planned**
Plan: docs/plans/2026-09-25-2226-backlog-sweep.md

## Problem

A task has no way to declare environment variables or a working directory for its steps. The task schema in `src/rite/config.lg` (`task-schema`, line 307) admits exactly `:doc`, `:args`, `:do`, `:depends`, `:deps`, `:paths`, and `:private?`; anything else is a config error. Steps run from wherever `rite` was invoked, since `run-sh-step!` in `src/rite/tasks.lg` (line 49) calls `(os/exec* "sh" "-c" cmd)` with no directory or environment control.

Two cases that came up in the first real `rite.edn` written against rite:

- A test task that needs `ELECTRON_DISABLE_SANDBOX=1` or `NO_COLOR=1` for one command. Today that is `{:sh "ELECTRON_DISABLE_SANDBOX=1 xvfb-run -a npx vscode-test"}`, which works for `sh` but reads as noise, has to be repeated per step, and is not available to `:run` steps at all.
- A task whose commands assume a subdirectory (`cd packages/cli && npm test`). The `cd &&` prefix is the only option, again per step, and it silently depends on rite finding `rite.edn` by walking up, so a task run from a sibling directory behaves the same as one run from the root only because of that walk.

Neither blocks anything, which is why the `sh -c` workarounds are acceptable for now. But every other task runner in this space (`just`, `task`, `mise` tasks, `bb` tasks) has both, and their absence is the first thing a user compares.

## Proposed fix

Two optional task keys, validated in `task-schema`:

- `:env` — a map of string keys to string or number values, applied to every step of the task. Values may use `{{arg/...}}` and `{{var/...}}` templates like any other string, expanded with the same `args/expand` used by `sh-command`.
- `:cwd` — a path relative to the `rite.edn` directory, validated with the existing `rel-path-schema` (`config.lg`, line 57), applied to every step of the task.

The mechanism already exists in the codebase: `exec-script!` in `src/rite/script.lg` sets `RITE_SCRIPT` and friends with `os/setenv` around `os/exec*` and restores them afterwards. Do the same for `:env` around each step, and use `syscall/chdir` for `:cwd` with a restore to the previous directory. `os/setenv` is in let-go's `os` namespace (`pkg/rt/os.go`) and `chdir` in its `syscall` namespace (`pkg/rt/syscall_linux.go`), both in 1.12.2; `syscall/chdir` is a stub that errors on non-linux builds (`pkg/rt/syscall_other.go`); check the darwin binary before relying on it, and if `chdir` is missing there, prefix the `sh -c` command with `cd <quoted cwd> &&` instead and document that `:cwd` applies to `:sh` steps only.

Notes for whoever picks this up:

- Task-level, not step-level. A step-level `:env` is easy to add later; a task-level one covers the two cases above and keeps the schema small.
- Restore is mandatory: the same rite process runs the next plan entry, and a leaked `cd` or variable would change its behaviour. Follow the restore pattern and its `LG_SOURCE_PATHS` caveat in `exec-script!`.
- `--verbose` should print the resolved env and cwd, the way `env-trace-line` does for `:run` steps.
- Reject `:env` keys that collide with the ones rite manages itself (`RITE_SCRIPT`, `LG_SOURCE_PATHS`, `LG_READ_CLJ`) at load time, with a message like the existing placeholder errors in `config.lg`.
- Unit-test the schema in `test/rite/config_test.lg`; test the actual env and cwd effect in `tests/run.sh` with a step that prints `$PWD` and the variable.

Roughly forty lines across `config.lg`, `tasks.lg`, and `script.lg`, plus README sections for the two keys.

## Origin

Raised on 2026-09-25 while writing the `rite.edn` for the quickdiff VS Code extension, where a headless test task wanted a per-task variable and the `sh -c` prefix was the only option.
