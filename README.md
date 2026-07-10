# rite

A single-binary task runner for any project. Define tasks in `rite.edn`, then
run them with `rite <task>`.

rite is a [let-go](https://github.com/nooga/let-go) program bundled into one
executable, so the binary carries the full let-go compiler. `:run` steps
execute let-go scripts in-process, with no separate `lg` on the machine.

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

```sh
VERSION=0.1.0
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # linux | darwin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSL -o rite.tar.gz \
  "https://github.com/abogoyavlensky/rite/releases/download/v${VERSION}/rite_${VERSION}_${OS}_${ARCH}.tar.gz"
tar -xzf rite.tar.gz
mv rite ~/.local/bin/
```

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
rite              # print usage and the task list
rite tasks        # print just the task list
rite fmt          # run the fmt task
rite check        # run fmt, then test
```

rite finds `rite.edn` by walking up from the current directory, so you can run
tasks from any subdirectory.

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
          :depends [check [notify :arg/env]]
          :do [{:sh ["./deploy.sh" :arg/env]}
               {:sh "echo released {{version}}"}]}

  notify {:args [{:name :env}]
          :deps {abogoyavlensky/tiny-cli {:git/url "https://github.com/abogoyavlensky/tiny-cli"
                                          :git/tag "0.1.0"}}
          :paths ["scripts"]
          :do {:run ["scripts/notify.lg" :arg/env]}}}}
```

### `:vars`

A map of unqualified keyword to string or number. Numbers become strings. Vars
are flat: one var cannot reference another. Reference a var as `{{name}}` in any
step string or as `:var/name` in a step vector.

### Tasks

Each task is a map. The keys are `:doc`, `:args`, `:do`, `:depends`, `:deps`,
and `:paths`; any other key is an error. A task needs at least a `:do` or a
`:depends`.

Task names are symbols (`fmt`, not `:fmt`). These names are reserved for the
built-in commands and cannot be task names: `help`, `version`, `tasks`,
`completion`, `__complete`.

#### `:do` steps

`:do` is one step map or a vector of step maps. Steps run top to bottom. The
first step to exit non-zero stops the task and becomes its exit code. Output
streams live, so progress bars and interactive prompts work.

Each step has exactly one action key:

- `{:sh "cljfmt fix"}` runs the command with `sh -c`.
- `{:run ["scripts/notify.lg" "prod"]}` runs a let-go script (see
  [`:run` steps](#run-steps-the-embedded-runtime)).

A step value is a string or a vector. A vector `:sh` value joins its items with
spaces after substitution; a vector `:run` value passes its items through as the
script's argv.

#### Placeholders

A step value can reference the task's bound args and the project vars two ways:

- `:arg/<name>` and `:var/<name>` keywords in a **vector** substitute the whole
  item. In `:sh` the value is shell-quoted (so a value with spaces stays one
  argument); in `:run` it is passed verbatim.
- `{{name}}` in any **string** splices the value in raw, with no quoting. rite
  looks up `name` as an arg first, then as a var, so an arg shadows a var of the
  same name. An unknown `{{...}}` token passes through untouched.

rite validates keyword placeholders when it loads the config: an `:arg/*` must
name a declared arg, a `:var/*` must name a defined var. `{{...}}` tokens are
never a load error.

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
a string (with `{{...}}` expansion), `:arg/<name>` (forwarding this task's bound
arg), or `:var/<name>`.

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

Steps run from the directory where you invoked rite, so `:sh` commands and
`:run` script paths resolve against your working directory, while `:deps` and
`:paths` resolve against the project root.

**Limitation:** a bundled binary serves `io/resource` only from the archive
embedded at build time, so rite has no `:resource-paths` and `io/resource` is
not available to task scripts. Read files with `slurp` instead.

## CLI

```
rite                     # usage and task list (same as `rite help`)
rite help | -h | --help  # same
rite tasks               # just the task list
rite version             # print the version
rite <task> [args...]    # run a task
rite --verbose <task>    # also print the resolved :run invocation and env
```

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `RITE_HOME` | `$XDG_CACHE_HOME/rite`, else `~/.cache/rite` | State root for the dependency cache. The layout matches lgx's, so set `RITE_HOME=~/.lgx` to reuse lgx's cache. A relative `XDG_CACHE_HOME` is ignored, per the XDG spec. |
| `RITE_NO_COLOR` | unset | Set to any non-empty value to disable colored headers and step markers. |

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
its own flags before the entry script.

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
