# Colored status output is emitted when stderr is not a terminal

**Status: open**

## Problem

Task headers and `$` step markers carry ANSI escape codes even when rite's output is captured by a pipe, a file, a CI log, or an agent harness. A captured run looks like this:

```
[38;5;98m=> Running task test-unit...[0m

[38;5;98m$[0m echo unit
```

The only way to get clean output is to set `RITE_NO_COLOR`, which every CI job and every wrapper script has to know about.

The cause is `color-enabled?` in `src/rite/style.lg` (line 18), which checks nothing but that variable. The comment above it (line 12) says "let-go has no TTY detection, so color cannot be auto-disabled when piped." That was true when it was written but is stale now: let-go ships `term/tty?` (`pkg/rt/term.go`, `ns.Def("tty?", ...)`, added in let-go v1.10.0), and rite pins `:lg-version "1.12.2"` in `lgx.edn`, which has it. The predicate takes a file-backed IOHandle such as `*err*` and returns whether it is a terminal.

The headers all go to `*err*` (see the comment at the top of `style.lg`), so the check has to be against stderr, not stdout.

## Fix

Make `color-enabled?` return false when either `RITE_NO_COLOR` is set or `(term/tty? *err*)` is false. While there, honor the de facto standard `NO_COLOR` variable too, since tools like this are expected to; keep `RITE_NO_COLOR` as the project-specific override. The precedence is simple: any of the three conditions disables color.

Notes for whoever picks this up:

- `term/tty?` is unavailable on the `js`, `plan9`, and `wasip1` build tags of let-go. rite only ships linux and darwin binaries, so this is safe, but wrap the call so a runtime error falls back to "not a tty" rather than crashing a task run.
- `color-enabled?` is private and called on every header; calling `tty?` each time is cheap, but a `delay` is fine if it reads better.
- Update the stale comment in `style.lg` and the `RITE_NO_COLOR` row in the README's environment table to say color is also off when stderr is not a terminal.
- The style unit tests in `test/rite/style_test.lg` run under `lgx test` with stderr captured, so after this change they will see uncolored output by default. Set `RITE_NO_COLOR` explicitly in the tests that assert on plain strings, and test the colored form by injecting the predicate rather than depending on a real terminal.

About ten lines in `style.lg` plus test adjustments.

## Origin

Noticed on 2026-09-25 while running rite 0.1.1 from an agent session whose Bash tool captures output through a pipe; every task run came back with raw escape sequences.
