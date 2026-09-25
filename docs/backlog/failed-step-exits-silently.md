# A failing step ends the run with no message naming the task or step

**Status: planned**
Plan: docs/plans/2026-09-25-2226-backlog-sweep.md

## Problem

When a `:do` step exits non-zero, rite stops and exits with that code, but prints nothing about what failed. The last thing on the terminal is whatever the step itself wrote, which for a quiet command is nothing at all.

Repro with this `rite.edn`:

```edn
{:tasks
 {fail {:do [{:sh "echo first"} {:sh "false"} {:sh "echo should-not-run"}]}}}
```

```
$ rite fail
=> Running task fail...

$ echo first
first

$ false
$ echo $?
1
```

The cause is in `src/rite/tasks.lg`. `run-entry!` (line 67) returns the first non-zero exit and `run-plan!` (line 90) calls `os/exit` with it directly, so neither function writes anything to `*err*` on the failure path. The per-step `$ <cmd>` line printed by `run-sh-step!` (line 49) is the only trace of which step ran last.

In practice this matters most in `:depends` chains and CI logs: with `check {:depends [fmt lint test]}` the reader has to scroll back to the last `$` line to guess which task's step failed, and a step that fails silently (a `false`, a script that only sets an exit code) leaves no visible evidence at all. The exit code itself is propagated correctly; that part works.

## Fix

Write one styled line to `*err*` before exiting, from `run-plan!`, where both the entry name and the exit code are known: something like `=> Task fail failed: step 2 exited with 1`. For that `run-entry!` has to return the step index alongside the code, for example `{:exit 1 :step 2}` with `{:exit 0}` on success, or keep returning the number and have the loop in `run-entry!` write the line itself, where the step index is in hand.

Notes for whoever picks this up:

- Keep the exit code as the process status; the message is additive.
- Put the message on `*err*`, like the headers, so stdout stays reserved for program output (see the comment at the top of `src/rite/style.lg`).
- Add a `failure-line` fn to `src/rite/style.lg` so it is pure and unit-testable, mirroring `task-header` and `step-line`. Cover it in `test/rite/style_test.lg`; cover the end-to-end message in `tests/run.sh`, since `run-plan!` is only exercised there (see the note at the top of `test/rite/tasks_test.lg`).
- Mention the line in the README section on `:do` steps, next to "The first step to exit non-zero stops the task and becomes its exit code."

About fifteen lines across `tasks.lg` and `style.lg`, plus the two tests.

## Origin

Noticed on 2026-09-25 while adopting rite 0.1.1 as the task runner for the quickdiff VS Code extension and probing failure behaviour before writing its `rite.edn`.
