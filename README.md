# rite

A single-binary task runner with an embedded let-go runtime. Define tasks in `rite.edn`, then
run them with `rite <task>`.

rite is a [let-go](https://github.com/nooga/let-go) program bundled into one
executable, so the binary carries the full let-go compiler. `:run` steps
execute let-go scripts in-process, with no separate `lg` on the machine.

## Quickstart

Put a `rite.edn` at your project root:

```edn
{:tasks
 {fmt   {:doc "Format sources"
         :do {:sh "cljfmt fix"}}

  test  {:doc "Run the tests"
         :do {:sh "go test ./..."}}

  check {:doc "Format then test"
         :depends [fmt test]}}}
```

Then:

```bash
brew install abogoyavlensky/tap/rite  # install rite on macOS or Linux

rite              # print usage and the task list
rite tasks        # print just the task list
rite fmt          # run the fmt task
rite check        # run fmt, then test
```

rite finds `rite.edn` by walking up from the current directory, so you can run
tasks from any subdirectory.


## Installation

### With [Homebrew](https://brew.sh)

Works on macOS and Linux:

```sh
brew install abogoyavlensky/tap/rite
```

### With [mise](https://mise.jdx.dev)

```sh
mise use -g github:abogoyavlensky/rite@latest
```

Or pin a version in `.mise.toml`:

```toml
[tools]
"github:abogoyavlensky/rite" = "latest"
```

### Manual

Download the archive for your platform from the
[releases page](https://github.com/abogoyavlensky/rite/releases), extract it, and
put `rite` on your `PATH`:

## `rite.edn` reference

The root map takes two optional keys, `:vars` and `:tasks`. Any other key is an
error. An empty `{}` is valid.

```edn
{:vars {:version "1.2.0"}          ; shared template values (optional)

 :tasks
 {fmt    {:doc "Format sources"
          :do {:sh "cljfmt fix"}}

  lint   {:doc "Lint sources"
          :do {:sh "clj-kondo --lint src"}}

  check  {:doc "All checks"
          :depends [fmt lint]}      ; aggregate task: :depends without :do

  deploy {:doc "Deploy a release"
          :args [{:name :env :type [:enum "prod" "staging"]}]
          :depends [check]
          :do [{:sh ["./deploy.sh" :arg/env]}
               {:task [notify :arg/env]}  ; run another task as a step
               {:sh "echo released {{var/version}}"}]}

  notify {:args [{:name :env}]
          :deps {tiny-cli {:git/url "https://github.com/abogoyavlensky/tiny-cli"
                           :git/tag "0.1.0"}}
          :paths ["scripts"]
          :do {:run ["scripts/notify.lg" :arg/env]}}}}
```

### `:vars`

A map of unqualified keyword to string or number. Numbers become strings. Vars
are flat: one var cannot reference another. Reference a var as `{{var/name}}` in
any step string or as `:var/name` in a step vector.

### Tasks

Each task is a map. The keys are `:doc`, `:args`, `:do`, `:depends`, `:deps`,
`:paths`, `:private?`, `:env`, and `:cwd`; any other key is an error. A task
needs at least a `:do` or a `:depends`.

Task names are symbols (`fmt`, not `:fmt`). These names are reserved and cannot
be task names: `tasks` (the built-in command), plus `completion` and
`__complete` (reserved for a future shell-completion command). `help` and
`version` are flags (`-h`/`--help`, `-v`/`--version`), not commands, so they are
free to use as task names.

#### `:do` steps

`:do` is one step map or a vector of step maps. Steps run top to bottom. The
first step to exit non-zero stops the task and becomes its exit code. rite then
prints `=> Task <name> failed: step <n> exited with <code>` to stderr, so a quiet
failure in a long `:depends` chain still says where it stopped. Output streams
live, so progress bars and interactive prompts work.

Each step has exactly one action key:

- `{:sh "cljfmt fix"}` runs the command with `sh -c`.
- `{:run ["scripts/notify.lg" "prod"]}` runs a let-go script (see
  [`:run` steps](#run-steps-the-embedded-runtime)).
- `{:task fmt}` or `{:task [notify "prod"]}` runs another task (see
  [`:task` steps](#task-steps)).
- `{:parallel [{:sh "..."} {:task dev-web}]}` runs several commands at once
  (see [`:parallel` steps](#parallel-steps)).

A step value is a string or a vector. A vector `:sh` value joins its items with
spaces after substitution; a vector `:run` value passes its items through as the
script's argv.

A `:sh` string may span several lines; `sh -c` runs it as one script. The step
line then shows only the first line and a count of the rest, such as
`$ if ! git diff --quiet; then … (+3 lines)`. `--verbose` prints the whole
script.

```edn
release-check {:do {:sh "
  if ! git diff --quiet; then
    echo 'uncommitted changes' >&2
    exit 1
  fi"}}
```

#### Placeholders

A step value can reference the task's bound args and the project vars two ways:

- `:arg/<name>` and `:var/<name>` keywords in a **vector** substitute the whole
  item. In `:sh` the value is shell-quoted (so a value with spaces stays one
  argument); in `:run` it is passed verbatim.
- `{{arg/<name>}}` and `{{var/<name>}}` tokens in any **string** splice the
  value in raw, with no quoting. Whitespace inside the delimiters is
  insignificant: `{{ var/version }}` works the same as `{{var/version}}`.

Any other `{{...}}` content is not a token and passes through untouched —
`{{name}}`, `{{ github.sha }}`, an unclosed `{{` — so text destined for other
template tools is safe inside step strings.

rite validates both placeholder forms when it loads the config: an `arg/*`
placeholder must name a declared arg, a `var/*` placeholder must name a
defined var.

#### `:env` and `:cwd`

`:env` sets environment variables for every step of the task. It is a map of
variable names (strings) to string or number values, and the values take the
same `{{arg/*}}` and `{{var/*}}` tokens as step strings. rite sets the variables
around each step and restores the previous values afterwards; a variable that
was unset comes back empty, since let-go cannot unset one. `RITE_SCRIPT`,
`LG_SOURCE_PATHS`, and `LG_READ_CLJ` are managed by rite and are rejected.

`:cwd` is a directory relative to the project root. Every step of the task runs
from it, wherever you invoke rite, and a `:run` script path resolves against
it. A missing directory fails the first step.

```edn
test {:env {"NO_COLOR" "1"}
      :cwd "packages/cli"
      :do {:sh "npm test"}}
```

A `:sh` or `:run` step can set its own `:cwd`, also relative to the project
root. It replaces the task's directory for that step only; the next step runs
from the task's directory again. A `:task` step takes no `:cwd`: set it on the
called task instead.

```edn
deps {:do [{:sh "go mod download"}
           {:sh "npm ci" :cwd "web"}]}
```

Both keys apply to the task's own steps, not to the tasks in its `:depends`.
A task called by a [`:task` step](#task-steps) inherits them. `--verbose`
prints the resolved `:env` and the `cd` that applies `:cwd`.

#### `:fail-on-output`

`:fail-on-output true` on a `:sh` step fails the step when the command prints
anything to stdout, even if it exits 0. Use it for checks whose findings are
their output, such as "list untracked generated files":

```edn
gen-check {:do [{:sh "git diff --exit-code -- gen"}
                {:sh "git ls-files --others --exclude-standard -- gen"
                 :fail-on-output true}]}
```

A command that exits non-zero fails with its own code. One that exits 0 but
prints to stdout fails with 1, after `=> step printed output; expected none`.
Output on stderr does not count, so a tool can still warn.

The step's output is buffered: rite prints it when the command finishes, stdout
first, then stderr. Keep it for quick checks. The key is rejected on `:run`,
`:task`, and `:parallel` steps.

#### `:args`

`:args` declares positional arguments, filled left to right from the command
line.

```edn
:args [{:name :env :type [:enum "prod" "staging"]}
       {:name :port :type :int}
       {:name :tag :default "latest"}]
```

- `:name` is an unqualified keyword.
- `:type` is `:string` (the default), `:int`, or `[:enum "a" "b" ...]`.
- `:default` makes the arg optional. Once one arg has a default, every later arg
  must have one too.

All bound values are strings; `:int` and `:enum` only validate the input. A bad
value prints the error and the usage line, then exits 1.

#### `:depends`

`:depends` is a vector of entries that run before the task's own steps,
depth-first and in listed order. An entry is either a task symbol (`fmt`) or a
vector `[task-sym item...]` that passes arguments to the dependency. Each item is
a string (with `{{arg/*}}`/`{{var/*}}` expansion), `:arg/<name>` (forwarding this
task's bound arg), or `:var/<name>`.

```edn
deploy {:args [{:name :env :type [:enum "prod" "staging"]}]
        :depends [check [notify :arg/env]]}
```

rite flattens the whole invocation into one ordered plan and dedupes it by task
name and resolved arguments. A diamond dependency runs once. The same task
invoked with different arguments runs once per distinct argument set. The first
dependency to exit non-zero aborts the run with that exit code.

At load time rite checks that every `:depends` entry names a defined task, that
forwarded placeholders name a declared arg or defined var, that literal
arguments match the dependency's `:args`, and that the task graph has no cycle.

#### `:task` steps

A `{:task ...}` step runs another task at that point in `:do`, between the
steps around it. Its value has the same shape as a `:depends` entry: a task
symbol, or a vector of the task symbol followed by its arguments.

```edn
ci {:args [{:name :env}]
    :do [{:sh "docker compose up -d"}
         {:task fmt}                    ; no arguments
         {:task [notify :arg/env]}      ; with a forwarded arg
         {:sh "docker compose down"}]}
```

The step behaves like running `rite <task> args` at that point, but inside the
same rite process. The called task runs its own `:depends` first, then its
steps, each with its usual header, and the step line reads
`$ rite notify prod`. Unlike `:depends`, a call is never deduped: a task that
both depends on `fmt` and calls `{:task fmt}` runs fmt twice. Use `:depends`
for prerequisites that should run once. Use `:task` when the order among your
own steps matters, for example a task that must run between a setup step and a
cleanup step.

A called task inherits the caller's `:env`, with its own `:env` layered on top.
It runs from its own `:cwd` if it sets one, and otherwise from the caller's
directory. The tasks in its `:depends` inherit the same way.

If a step inside the call fails, rite prints the failing task's failure line,
then the caller's (`=> Task ci failed: step 3 exited with 1`), and exits with
the failing step's code.

At load time rite checks a `:task` step the same way it checks a `:depends`
entry: the task must be defined, forwarded placeholders must name a declared
arg or defined var, and literal arguments must match the task's `:args`. The
cycle check covers `:depends` and `:task` together, so a task can't call itself
directly or through another task.

#### `:parallel` steps

A `{:parallel [...]}` step runs its children at the same time and waits for all
of them. Each child is one of:

- `{:sh "<command>"}`, with an optional `:cwd` and `:label`;
- `{:task <entry>}`, with an optional `:label`. The entry has the same shape as
  a `:task` step's value: `dev-api` or `[serve "8080"]`.

```edn
dev {:doc "Run the API and the Vite dev server together"
     :do {:parallel [{:task dev-api}
                     {:sh "npm run dev" :cwd "web" :label "web"}]}}
```

Every output line, stdout and stderr alike, starts with the child's label:

```
[dev-api] listening on :8080
[web]     VITE ready in 312 ms
```

A `:task` child's label defaults to its task name and a `:sh` child's to the
first word of its command (`go`, `npm`). A repeated default gets a suffix
(`go`, `go-2`); a repeated explicit `:label` is an error.

How the step ends:

- A child that exits 0 stops nothing. The step finishes when every child has
  finished, so `:parallel` works for "build both at once" as well as for
  long-running servers.
- The first child to exit non-zero stops the others. rite prints
  `=> <label> exited with <code>; stopping the others` and the step fails with
  that code.
- Ctrl-C or SIGTERM stops every child. The step exits 130 or 143.

To stop a child, rite sends TERM to the child's process tree, waits up to 5
seconds, then sends KILL to whatever is left. A process that leaves its tree
(a daemon, or a command that calls `setsid`) cannot be stopped this way.

Children read no stdin, so a child cannot prompt. The task's `:env` reaches
every child. A `:sh` child runs from its own `:cwd`, otherwise from the task's
directory. A `:task` child runs `rite <task> args` as a separate process from
the project root, so its own `:cwd` and `:env` apply as usual. Its arguments
are resolved like a `:task` step's. `:parallel` children cannot be `:run` steps
or nested `:parallel` steps, and the step itself takes no `:cwd`.

`:parallel` runs its children under a small POSIX `sh` script, which needs
`mkfifo`, `mktemp`, `ps`, and `kill`; `pgrep` is used for the process-tree
walk when present. These are standard on Linux and macOS.

At load time a `:task` child is checked like a `:task` step, and the cycle check
covers it, so a task cannot start itself in parallel.

#### `:deps` and `:paths`

These set the basis for a task's `:run` steps and have no effect on `:sh` steps.

`:paths` is a vector of source directories, relative to the project root. rite
puts the project root and these directories on the script's namespace search
path, so a `:run` script can require project namespaces.

`:deps` fetches let-go libraries into a per-user cache shared across projects
(see `RITE_HOME` below). A coordinate is a git dependency or a local one:

```edn
:deps {owner/lib {:git/url "https://github.com/owner/lib"
                  :git/sha "abc123"}          ; or :git/tag "0.1.0"
       my/local  {:local/root "../my-local"}} ; optional :deps/root "src"
```

rite resolves transitive dependencies by reading each fetched library's own
`lgx.edn` (dependencies are let-go libraries and declare their dependencies the
lgx way). On a version conflict the coordinate closest to your project wins, and
rite prints a warning.

rite fetches a task's `:deps` lazily, on the first `:run` step that needs them.
To fetch every task's `:deps` up front — for editor navigation, CI, or offline
work — run `rite tasks --deps`. It is idempotent: deps already in the cache are
left untouched.

#### `:private?`

`:private? true` hides a task from `rite --help`, `rite tasks`, and shell
completion. The task still runs directly (`rite <name>`) and stays a valid
`:depends` and `:task` target, so it suits helper tasks that other tasks build on but that
users rarely invoke by name. Omitting the key — or setting `:private? false` —
leaves the task visible.

## `:run` steps: the embedded runtime

A `:run` step runs a let-go script using rite itself as the runtime. rite
resolves the task's `:deps` and `:paths`, sets the namespace search path, and
re-executes its own binary in script mode. The script sees its arguments in
`*command-line-args*` and can `require` any namespace from the project `:paths`
or a fetched dependency.

```edn
notify {:paths ["scripts"]
        :deps {owner/tiny-cli {:git/url "https://github.com/owner/tiny-cli"
                               :git/tag "0.1.0"}}
        :do {:run ["scripts/notify.lg" :arg/env]}}
```

```clojure
;; scripts/notify.lg
(ns notify
  (:require [tiny-cli :as cli]))

(cli/send (str "deploying to " (first *command-line-args*)))
```

Steps run from the directory where you invoked rite, or from the task's `:cwd`
when it sets one (a task called by a `:task` step without its own `:cwd` runs
from the caller's directory), and `:sh` commands and `:run` script paths resolve against
that directory. `:deps` and `:paths` always resolve against the project root.

**Limitation:** a bundled binary serves `io/resource` only from the archive
embedded at build time, so rite has no `:resource-paths` and `io/resource` is
not available to task scripts. Read files with `slurp` instead.

## CLI

```
rite                     # usage and task list
rite -h | --help         # show this help
rite -v | --version      # print the version
rite tasks               # just the task list
rite tasks --deps        # fetch every task's :deps into the cache
rite <task> [args...]    # run a task
rite --verbose <task>    # also print the resolved :run invocation and env
rite completion <shell>  # print a bash/zsh/fish completion script
```

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RITE_HOME` | `$XDG_CACHE_HOME/rite`, else `~/.cache/rite` | State root for the dependency cache. The layout matches lgx's, so set `RITE_HOME=~/.lgx` to reuse lgx's cache. A relative `XDG_CACHE_HOME` is ignored, per the XDG spec. |
| `RITE_NO_COLOR` | unset | Set to any non-empty value to disable colored headers and step markers. Color is also off when stderr is not a terminal, so piped and CI output stays plain. |
| `NO_COLOR` | unset | The standard [opt-out](https://no-color.org); same effect as `RITE_NO_COLOR`. |

## Development

rite is built with [lgx](https://github.com/abogoyavlensky/lgx). Install the
toolchain with [mise](https://mise.jdx.dev):

```bash
mise trust && mise install
```

Then:

```bash
lgx test                 # unit tests
lgx build                # bundle bin/rite
bash tests/run.sh        # build, unit tests, then the e2e suite (also `lgx e2e`)
lgx check                # fmt, lint, unit tests, and e2e
```

Develop the CLI against the built binary (`lgx build && ./bin/rite <task>`).
Running the CLI from source through `lgx run` does not dispatch, because lgx puts
its own flags before the entry script. A `:task` child of a `:parallel` step
also needs the built binary: it re-runs rite's own executable, which from
source is `lg`.

### Releasing

The version lives in one place, `resources/VERSION`. Bump it, commit, then tag:

```bash
printf '0.2.0' > resources/VERSION      # no trailing newline
git add resources/VERSION && git commit -m "Release 0.2.0"
lgx release                             # tags v0.2.0 and pushes the tag
```

The pushed tag triggers `.github/workflows/release.yml`, which builds the four
platform binaries, publishes a GitHub Release, and updates the Homebrew formula
in `abogoyavlensky/homebrew-tap`. This needs two one-time setup steps: a public
`homebrew-tap` repo under your account, and a `HOMEBREW_TAP_TOKEN` repository
secret (a PAT with write access to that tap).

## Shell completions

`rite` completes task names and a task's enum argument values on TAB. Load the
script for your shell:

**bash** — add to `~/.bashrc`:

```bash
source <(rite completion bash)
```

**zsh** — save it on your `fpath` (e.g. `~/.zfunc`, which must be on `fpath`
before `compinit` runs):

```zsh
rite completion zsh > ~/.zfunc/_rite
```

Or source it directly from `~/.zshrc`: `source <(rite completion zsh)`.

**fish** — save it where fish loads completions:

```fish
rite completion fish > ~/.config/fish/completions/rite.fish
```

Completion covers the command position (your project's task names plus `tasks`)
and, once a task is typed, that argument's `[:enum ...]` values. It reads the
enclosing project's `rite.edn`, so it always reflects the current project's
tasks; outside a project, or with an invalid `rite.edn`, it stays quiet rather
than erroring.

## License

MIT License. Copyright (c) 2026 Andrey Bogoyavlenskiy.
