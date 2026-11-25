# mise-tasks patterns in entireio/cli

Research for [#4](https://github.com/mguilarducci/agent-skills/issues/4), part of map [#2](https://github.com/mguilarducci/agent-skills/issues/2) (Herdr subagent script).

Question: how does [entireio/cli](https://github.com/entireio/cli/tree/main/mise-tasks) lay out its mise tasks, what does `setup` do, how are tests split and run, how does CI invoke tasks, and how are tools pinned? What fits a small bash-script repo?

Sources (read 2026-11-25):

- entireio/cli at commit [`cef49f9`](https://github.com/entireio/cli/tree/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb): `mise-tasks/**`, `mise.toml`, `.github/workflows/{ci,lint,e2e}.yml`, `CONTRIBUTING.md`, `.devcontainer/`.
- mise docs: [File tasks](https://mise.jdx.dev/tasks/file-tasks.html), [Task discovery](https://mise.jdx.dev/tasks/task-discovery.html), [Task configuration](https://mise.jdx.dev/tasks/task-configuration.html), [Tasks overview](https://mise.jdx.dev/tasks/).
- A local probe with mise `2026.11.14` in a throwaway directory (marked **[probe]** below).

## TL;DR

- entireio/cli uses **one executable file per task**, grouped by **folders** that become `:`-separated names (`mise-tasks/test/ci/core` is `test:ci:core`). A folder's `_default` file is the bare group name (`lint/_default` is `lint`, and it only aggregates via `#MISE depends=[...]`).
- Metadata lives in `#MISE` header comments; arguments in `#USAGE` comments, read as `usage_*` env vars.
- **There is no `setup` task.** Setup is `mise trust && mise install` (documented in `CONTRIBUTING.md`, automated in `.devcontainer/post-create.sh`); tools come from `[tools]` in `mise.toml`.
- **There are no helper files beside tasks.** Every file under `mise-tasks/` is a task. Longer non-task scripts live in `scripts/`, and a few tasks call them.
- Short one-liner tasks stay inline in `mise.toml` (`fmt`, `test`, `test:integration`, `check`). A custom lint task (`lint:mise`) fails if any `run = """..."""` block in `mise.toml` has 3+ lines, so longer scripts must move into `mise-tasks/`.
- CI installs tools with `jdx/mise-action` (pinned by SHA) and then runs **the same tasks a developer runs** (`mise run lint`, `mise run test:ci:core`, `mise run test:ci:integration:shard -- a`).
- For our repo: copy the layout, `#MISE`/`#USAGE` headers, `_default` aggregators and "CI calls mise tasks". Skip sharding, benchmarks and release tasks. A `setup` task is optional. Keep bats PATH stubs **out of** `mise-tasks/`, because executable files there turn into tasks.

## How tasks are laid out

### Files and folders

Tree at `cef49f9`, with every file executable ([`mise-tasks/`](https://github.com/entireio/cli/tree/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/mise-tasks)):

```
mise-tasks/
  build  completions  release  winversion          # top-level single tasks
  bench/{_default,compare,cpu,mem}
  complexity/gate
  dev/publish
  dup/{_default,staged}
  lint/{_default,go,gofmt,gomod,licenses,mise,secretpatterns,shellcheck,vuln}
  test/ps1
  test/ci/core
  test/ci/canary/shard
  test/ci/integration/shard
  test/e2e/{_default,canary,controlplane,roger-roger}
```

- **Naming.** Files have no extension. The path below `mise-tasks/` becomes the name, with `/` turned into `:`: `test/ci/integration/shard` is `test:ci:integration:shard`. mise also strips script extensions such as `.sh` from names ([File tasks](https://mise.jdx.dev/tasks/file-tasks.html)), but entireio doesn't use extensions.
- **`_default`.** "A file named `_default` takes its directory's name" ([File tasks](https://mise.jdx.dev/tasks/file-tasks.html)). entireio uses it for group entry points: `lint/_default` holds only headers (`#MISE depends=["lint:go", "lint:gofmt", "lint:gomod", "lint:mise", "lint:secretpatterns", "lint:shellcheck"]`). `lint:licenses` and `lint:vuln` are deliberately left out, because they touch the network ([`lint/vuln`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/mise-tasks/lint/vuln) comment). `test/e2e/_default` is a real task (`test:e2e --agent X`).
- **Shebangs.** There is a mix of `#!/bin/sh` (`set -eu`) and `#!/bin/bash` / `#!/usr/bin/env bash` (`set -euo pipefail`).
- **Helper files beside tasks: none.** Every file under `mise-tasks/` is an executable task. Reusable or long logic lives in top-level `scripts/` (for example `scripts/test-release-origins.sh`, `scripts/create-nightly-tag.sh`, `scripts/test/*.ps1`). Tasks either call those scripts (`release` calls `scripts/create-nightly-tag.sh`; `test:ps1` runs `scripts/test/run.ps1`) or are wired from `mise.toml` (`[tasks."test:release-origins"] run = "scripts/test-release-origins.sh"`).
- **Inline TOML tasks too.** `mise.toml` defines `fmt`, `test`, `test:integration`, `test:ci`, `test:release-origins`, `check` (`depends = ["fmt", "lint", "test:ci"]`), `build:windows` and `build:windows-arm64` ([`mise.toml`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/mise.toml)). The mise docs back this split: "Start with TOML and move a script into a file when it grows" ([Tasks](https://mise.jdx.dev/tasks/)). [`lint/mise`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/mise-tasks/lint/mise) enforces it with awk, failing on any multi-line `run` block of 3+ lines in `mise.toml`.

### Headers

From the tasks and the [File tasks](https://mise.jdx.dev/tasks/file-tasks.html) docs:

- `#MISE description="..."` appears on every task. It shows in `mise tasks ls`.
- `#MISE depends=[...]` is used for aggregators (`lint/_default`).
- `#MISE quiet=true` is used on `completions`, `winversion` and `test/e2e/*`.
- `#USAGE arg "<shard>" help="..."`, `#USAGE arg "[filter]" ... default=""` and `#USAGE flag "--agent <agent>" ... env="E2E_AGENT"` declare arguments. Scripts read them as `usage_shard`, `usage_filter` and `usage_agent`. mise "passes each value to the script as a `usage_*` environment variable" and generates `--help` and completions from them ([File tasks](https://mise.jdx.dev/tasks/file-tasks.html)). Older tasks still read `$1` (`release`, `winversion`). `dev/publish` reads both (`${usage_target:-${1:-}}`).
- Other header keys the docs allow, and entireio doesn't use: `alias`, `sources`, `tools={...}` (per-task tools). Header lines accept any task property except `run`, `run_windows`, `file` and `usage`.

### Discovery rules worth knowing (mise docs and probe)

- Default task dirs, in order: `mise-tasks`, `.mise-tasks`, `.mise/tasks`, `.config/mise/tasks`, `mise/tasks` ([Task discovery](https://mise.jdx.dev/tasks/task-discovery.html)).
- mise "loads every executable file as a file task and every `.toml` file that is not a mise config file as a TOML task file". It "skips files and subdirectories inside them whose names start with `.`" ([Task discovery](https://mise.jdx.dev/tasks/task-discovery.html)).
- **[probe]** A **non-executable** helper such as `mise-tasks/test/_lib.sh` is ignored by `mise tasks ls`, and a task can `source "$(dirname "$0")/_lib.sh"`. That is the safe way to keep a helper next to a task.
- **[probe]** An **executable** file in a subfolder becomes a task: `mise-tasks/test/helpers/stub-git` showed up as `test:helpers:stub-git`. Executable PATH stubs for bats must therefore live outside `mise-tasks/`, in a dot-directory, or behind `[task_config] excludes = ["mise-tasks/test/helpers"]` (which removed it in the probe; see [Task discovery](https://mise.jdx.dev/tasks/task-discovery.html)).
- **[probe]** `#MISE depends=["test:*"]` ran `test:unit` but not the nested `test:helpers:stub-git`. The glob matched one level only.

## What `setup` does

entireio has **no `setup` task**. Onboarding per [`CONTRIBUTING.md`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/CONTRIBUTING.md) is:

```bash
mise trust      # required on first setup
mise install    # installs Go and the other tools from mise.toml
go mod download
mise run build
mise run test
```

The dev container automates this: `.devcontainer/post-create.sh` runs `mise trust --yes && mise install` (`CONTRIBUTING.md`, "Dev Container" section). Some tasks bootstrap their own missing tools at run time (`lint/licenses` runs `go install go-licenses@latest` if it's absent), and some check for their prerequisites and fail fast (`bench/compare` checks for `benchstat`; `test/e2e/roger-roger` checks for its binaries and says "Install it via 'mise install'").

## How tests are split and run

- **Dev entry points (TOML, one-liners):** `mise run test` (unit, gotestsum), `test:integration` (build tag `integration`), and `test:ci` (everything with `-race`, then `mise run test:e2e:canary`).
- **CI-only entry points (file tasks under `test/ci/`):**
  - `test:ci:core` runs every package except the integration package, with `-race -parallel=$GO_TEST_PARALLEL`.
  - `test:ci:integration:shard <a|b|c>` lists tests with `go test -list` and buckets them by name pattern into shards a, b and c, with c as the catch-all.
  - `test:ci:canary:shard <shard> <total>` enumerates E2E test functions from source, checks that none escaped the enumeration, and runs one shard.
- **E2E:** `test:e2e --agent X [filter]` runs against real agents; `test:e2e:canary`, `test:e2e:roger-roger` and `test:e2e:controlplane` cover the other variants. All of them write artifacts under `e2e/artifacts/<timestamp>`.
- **Other languages:** `test:ps1` runs the Pester tests in `scripts/test/` and skips with exit 0 when `pwsh` is absent.
- **Shell lint:** [`lint/shellcheck`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/mise-tasks/lint/shellcheck) finds every file in `mise-tasks/` and `scripts/` whose shebang is sh or bash and runs `shellcheck` on them. Policy lives in a repo `.shellcheckrc` ("overrides any ~/.shellcheckrc ... so local lint matches CI"). There is **no shfmt** and **no bats** in entireio.

## How CI invokes tasks

[`ci.yml`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/.github/workflows/ci.yml), [`lint.yml`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/.github/workflows/lint.yml), [`e2e.yml`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/.github/workflows/e2e.yml):

- Each job runs `actions/checkout` and then `jdx/mise-action@<sha> # v4`. The action installs everything in `[tools]`. Then a step runs a single `mise run <task>`:
  - `mise run lint`
  - `mise run test:ci:core`
  - `mise run test:release-origins`
  - `mise run test:ci:integration:shard -- ${{ matrix.shard }}` (matrix `[a, b, c]`)
  - `mise run test:ci:canary:shard -- ${{ matrix.shard }} 3`
  - `mise run test:e2e:canary`
  - `mise run complexity:gate`
  - `mise run test:e2e --agent ... "$TEST_FILTER"`
- Task arguments come after `--`.
- Tasks are written to behave the same locally and in CI, with configuration through env vars (`GO_TEST_PARALLEL`, `BASE_REF`). One exception: `lint/go` skips `golangci-lint run` when `CI=true`, because CI uses `golangci-lint-action`. `lint.yml` reads that action's version from `mise.toml` with `sed` so the two can't drift.
- A few CI steps call `go test` directly instead of a task (Windows-only and Codex-hooks jobs).
- Every third-party action is pinned to a full commit SHA, with a `# vX` comment.

## How tools are pinned

From [`mise.toml`](https://github.com/entireio/cli/blob/cef49f99846b82ae2df3e68dc0e53d3ffc9e3bcb/mise.toml) `[tools]`:

- Exact versions: `go = '1.27.4'` (with a comment to keep it aligned with `go.mod`), `golangci-lint = '2.15.0'`, `go:...goversioninfo = 'v1.7.0'`, `go:...govulncheck = 'v1.9.0'`.
- `latest`: `shellcheck`, `tmux`, and the roger-roger `go:` binaries.
- A `postinstall` hook on `go` runs `go install ...dlv@latest && go install ...gotestsum@latest`.
- There is no `mise.lock` in the repo, and no per-task `tools=`.

## Fit for a small bash-script repo

Context from #2: the script lives in `scripts/<name>/`, must not need mise at runtime, and uses bats-core, shellcheck and shfmt installed by mise.

**Adopt:**

- File tasks under `mise-tasks/`, grouped by folder, with no extensions, every one executable and carrying `#MISE description=`.
- `_default` aggregators: `lint/_default` and `test/_default` holding only `#MISE depends=[...]`.
- `#USAGE` for task arguments (for example a bats filter), read via `usage_*`.
- CI runs `jdx/mise-action` (SHA-pinned) followed by `mise run lint` and `mise run test`. The commands are identical locally and in CI.
- A `lint:shellcheck` that finds shell files by shebang across `mise-tasks/` and `scripts/`, plus a repo `.shellcheckrc`.
- Keep the real logic in `scripts/`; tasks are thin wrappers. That is what keeps the script independent of mise at runtime.
- Exact pins for the tools we rely on. The registry has `bats` (`aqua:bats-core/bats-core`), `shfmt` (`aqua:mvdan/sh`) and `shellcheck` (`aqua:koalaman/shellcheck`) (checked with `mise registry` on 2026.11.14). This is stricter than entireio's `shellcheck = 'latest'`.

**Skip:**

- Sharding (`test:ci:*:shard`), benchmarks, `dup`, `complexity`, `release`, `winversion`, `dev:publish`, and the `CI=true` branch in lint. All of that is scale or Go specific.
- The `lint:mise` guard. Optional, and only worth adding if `mise.toml` grows inline scripts.
- A separate `test:ci` tier. One `test` is enough until the suite gets slow.

**Diverges from the map's assumptions:**

- The map's note "a task's helper files live next to it, e.g. `mise-tasks/setup`" is **not** an entireio pattern. entireio has no `setup` task and no helper files in `mise-tasks/`. Keeping helpers next to a task is possible in mise only for **non-executable** files (sourced `_lib.sh`) or inside dot-directories. Executable bats PATH stubs belong in the test tree (for example `scripts/<name>/test/stubs/`), not in `mise-tasks/`.
- A `setup` task is optional. Plain `mise install` already does what entireio's onboarding does. If we want one command for newcomers, `setup` could run `mise install` and check prerequisites (`git`, `hc`, `herdr-app` are not mise-managed).

### Suggested minimal layout

```
mise.toml                   # [tools] bats, shellcheck, shfmt pinned exactly
.shellcheckrc
mise-tasks/
  setup                     # optional: mise install + check git/hc/herdr-app exist
  fmt                       # shfmt -w over mise-tasks/ and scripts/
  lint/_default             # #MISE depends=["lint:shellcheck", "lint:shfmt"]
  lint/shellcheck           # shebang-based file discovery, like entireio
  lint/shfmt                # shfmt -d (check only)
  test/_default             # #MISE depends=["test:unit"], or runs bats directly
  test/unit                 # bats scripts/<name>/test  (#USAGE arg "[filter]")
scripts/<name>/
  <name>.sh                 # runtime entry point, no mise dependency
  lib/...                   # sourced helpers
  test/*.bats
  test/stubs/{git,hc,herdr-app,...}   # executable PATH stubs, outside mise-tasks
.github/workflows/ci.yml    # checkout -> jdx/mise-action@<sha> -> mise run lint -> mise run test
```

`fmt`, `lint` and `test` could start as one-line TOML tasks in `mise.toml` and move into files as they grow. Either way fits the docs and entireio's practice.
