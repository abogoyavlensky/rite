# `rite install` reads as toolchain setup but only fetches `:deps`

**Status: done**
Plan: docs/plans/2026-09-25-2226-backlog-sweep.md
Landed in: `src/rite/help.lg` (help row) and `src/rite/deps.lg` (no-deps message), Part A of the plan above.

## Problem

A newcomer scanning `rite --help` sees `rite install    Install all task dependencies` (`src/rite/help.lg`, line 18) next to `rite tasks` and assumes it installs what the project's tasks need, the way `npm install` or `mise install` do. It does not: it fetches the let-go git libraries declared in tasks' `:deps` into the cache for later `:run` steps, and does nothing for projects whose tasks are all `:sh` steps, which is most of them. The README's CLI table says the same thing more precisely (`fetch every task's :deps into the cache`), but the help text is what people read first.

The first thing a new user does with such a project is run `rite install` and get silence, then wonder whether it worked.

Narrow in practice: it costs one moment of confusion once per user, and nothing breaks.

## Why it is left alone

Renaming the command (`rite deps`, `rite fetch`) would break the one documented workflow in `docs/plans/2026-07-12-install-command.md` and any CI script already calling it, for a naming preference. Not worth it at this stage.

What is worth doing, and is small enough to do in passing the next time `help.lg` is touched: change the help line to match the README, for example `Fetch every task's :deps into the cache`, and have the command print `nothing to fetch: no task declares :deps` when that is the case, so the silence is explained. Both live in `src/rite/help.lg` and the install command path in `src/rite/cli.lg`; two lines and a test in `test/rite/help_test.lg`.

## Origin

Raised on 2026-09-25 while adopting rite 0.1.1 for a project with no `:run` steps.
