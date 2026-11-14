# A task whose name ends in `.lg` cannot be run from the command line

**Status: open**

## Problem

`cli/user-args` treats a second argv entry that ends in `.lg` as the dev-mode script path (`lg main.lg <cmd> ...`) and drops it. A task named `build.lg` is valid in `rite.edn`, but `rite build.lg` drops the name and prints help:

```edn
{:tasks {build.lg {:do {:sh "echo built"}}}}
```

```
$ rite build.lg
rite - task runner with an embedded let-go runtime
...
```

A `:task` step still runs such a task, because it runs in-process. A `:parallel` `:task` child re-runs rite as `rite build.lg`, so it hits the same bug: the child prints help and exits 0, and the step looks like it passed.

## Proposed fix

Decide dev mode from something other than the argument's suffix. One option is to compare `argv[1]` with the actual entry script, or to check whether `argv[0]` is `lg`. Another is to reject task names ending in `.lg` at load time.

## Origin

Found on 2026-11-14 by a codex review of the `:parallel` work (docs/plans/2026-11-14-0226-step-cwd-scripts-parallel.md).
