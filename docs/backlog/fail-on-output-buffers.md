# `:fail-on-output` buffers its step's output instead of streaming it

**Status: open**
Related: docs/plans/2026-11-14-0226-step-cwd-scripts-parallel.md

## Problem

A `:sh` step with `:fail-on-output true` (planned in the plan above) must both show its output and inspect it. let-go has two process primitives:

- `os/exec*` streams to `*out*`/`*err*` but returns only the exit code;
- `os/sh` returns `{:exit :out :err}` but only after the process ends.

So the planned step runs through `os/sh` and prints the captured output afterwards. For the intended use (quick checks such as "no untracked generated files"), that is fine. A long check gives no output until it finishes, and its stdout and stderr lose their relative order.

## Proposed fix

Stream and inspect at once. Either:

- let-go upstream: `os/exec*` that tees, for example an option that also returns the captured stdout; or
- rite: bind `*out*` to a writer that both forwards and records, if let-go gains a user-definable writer type that `os/exec*` will pipe into (it already pipes into non-file writers).

Then `:fail-on-output` can stream live, like every other step.

## Origin

Raised on 2026-11-14 while planning `:fail-on-output` for the kopi project's `gen-check` task.
