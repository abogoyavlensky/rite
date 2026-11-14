# `:parallel` cannot stop a child that leaves its process tree

**Status: open**
Related: docs/plans/2026-11-14-0226-step-cwd-scripts-parallel.md

## Problem

The `:parallel` step (planned in the plan above) runs its children under a POSIX `sh` supervisor. To stop the others when one child fails, or on Ctrl-C, the supervisor walks each child's process tree with `pgrep -P` and sends TERM bottom-up.

A walk by parent PID cannot reach a process that left the tree: a server that daemonizes, a command that calls `setsid`, or a grandchild re-parented to init after its parent exited. Such a process survives `rite`. When `pgrep` is missing (some minimal containers), the supervisor can only TERM each child's direct PID, and children that don't forward signals leak their own subprocesses.

The usual answer is a process group per child: start it with `setpgid`, then `kill -- -pgid`. That isn't available portably today:

- The shell's `set -m` gives background jobs their own groups, but dash refuses it without a tty ("can't access tty; job control turned off"), so it fails in CI and headless runs. Measured on 2026-11-14.
- let-go has `syscall/spawn`, `syscall/kill` and `syscall/signal-notify`, but only on Linux (`pkg/rt/syscall_linux.go`); other builds are stubs (`pkg/rt/syscall_other.go`). rite ships to macOS.
- `setsid(1)` is part of util-linux and absent on macOS.

## Proposed fix

Add a portable process primitive to let-go upstream, for example
`(os/spawn argv {:out f :err f :pgid true}) -> handle` with `os/wait`, `os/kill handle sig` (signalling the group) and a portable `os/signal-notify` for SIGINT and SIGTERM. Go's `os/exec` with `SysProcAttr{Setpgid: true}` covers Linux and macOS, so this is a small native addition.

With that primitive, rite could supervise `:parallel` children in let-go itself and drop the shell supervisor. That would also allow per-child colours and a precise exit report.

## Origin

Raised on 2026-11-14 while planning `:parallel` for the kopi project's `rite dev` (Go API plus Vite dev server).
