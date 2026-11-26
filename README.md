# agent-skills

Tools for launching and supervising coding agents from inside Herdr.

## Contributing

Dev tools (bats, shellcheck, shfmt) are pinned in `mise.toml`:

```sh
mise trust && mise install
```

## herdr-subagent

Starts a Herdr subagent from an `hc` template, in a new worktree on a new
branch (`start`), and cleans it up once its work is merged (`close`).
`herdr-subagent --help` is the full reference, with tips for the parent agent.

### Install

```sh
ln -s "$PWD/scripts/herdr-subagent/herdr-subagent.sh" ~/.local/bin/herdr-subagent
```

### Usage

Run it from a Herdr terminal, inside a git repo:

```sh
herdr-subagent start --branch feat/login <<'EOF'
Add OAuth login. Push the branch and open a PR against main.
EOF
hc wait --children any        # returns on the next report, block or exit
herdr-subagent close feat/login   # once the PR is merged
```

### start

- `--branch <name>` (required): the new branch. The worktree goes to
  `<main-checkout-root>/.worktrees/<slug(branch)>`.
- `--base <branch>`: the Base branch, a branch on `origin` to start from
  (default `main`). `start` fetches it and creates the new branch from
  `origin/<base>`; no local branch is ever written. No `origin`, a failed
  fetch, or a base missing on `origin` exits 3 and creates nothing.
- `--template <name>`: the hc template to launch from (default
  `implementer`). The template sets the Harness, model, effort, permissions
  and the child's fixed rules, and hc adds the report-back target, so only
  your task is sent. It must be listed by `hc templates`, which means a file
  at `~/.config/herdr-core/templates/<name>.md`. Copy or link the shipped ones:

  ```sh
  mkdir -p ~/.config/herdr-core/templates
  ln -s "$PWD"/scripts/herdr-subagent/templates/*.md ~/.config/herdr-core/templates/
  ```

  `implementer` runs Claude Code with `hc send` and `hc label` pre-allowed.
  `implementer-codex` runs Codex in its workspace-write sandbox with network
  access on: from inside that sandbox `hc` can't reach its core otherwise,
  and the child needs both `hc send` and `hc label`. A missing template
  exits 4 and creates nothing.
- `--parent <t>`: the live hc terminal that gets the reports (default
  `$HC_TERMINAL_ID`). Run it from an hc terminal, under `hc run --bg`, or pass
  `--parent`; without a live parent, `start` exits 4 and creates nothing.
- Labels: every Herdr subagent gets `subagent.repo` (the main checkout root),
  `subagent.branch` and `subagent.base`. `--issue <n>` (digits only) adds
  `subagent.issue`, and repeatable `--label k=v` adds your own. Keys under
  `subagent.`, `herdr.` or `where` are reserved (exit 2). Find them with
  `hc ls --label subagent.repo=<root>`.
- The task is read only from stdin, byte-for-byte, trailing newlines
  included. Use a quoted heredoc so quotes, `$` and backticks survive:

  ```sh
  herdr-subagent start --branch fix/docs <<'EOF'
  Fix the "quoted" $HOME and `backtick` bits in the docs.
  EOF
  ```

  An empty or whitespace-only task, or stdin attached to a terminal, exits 2.
- stdout is always one JSON line,
  `{"terminal","name","branch","base","worktree","template","issue","labels","task_sent","reason"}`,
  where `issue` is a number or `null`, `labels` holds every label applied,
  and `reason` is hc's reason when `task_sent` is false and `null`
  otherwise. stderr carries only
  progress, errors, leftovers after a failure and one final `started` line.
- An existing branch, worktree path or live hc name is never reused: `start`
  exits 5 before creating anything. Pick another name and retry.

### close

`herdr-subagent close <branch>` takes no flags. It finds the terminal by its
`subagent.repo` and `subagent.branch` labels (a finished one too), kills it,
and removes the worktree. A worktree with uncommitted or untracked changes
exits 3 and touches nothing. It then fetches the base (the terminal's
`subagent.base` label, else `main`) and deletes the local branch only when its
tip is an ancestor of `origin/<base>`, as a merge commit leaves it. Otherwise
the branch is kept and the reason reported; a failed fetch keeps it too. The
terminal's hc record is removed last, so a rerun still knows the base. There
is no `--force`, and rerunning `close` after a partial failure finishes the
cleanup, even when only the local branch is left. `close` only removes the
worktree `start` creates, `<main-checkout-root>/.worktrees/<slug(branch)>`: a
branch checked out in the main checkout or in any other worktree is refused
(exit 2).

stdout is one JSON line,
`{"branch","worktree","terminal_removed","worktree_removed","branch_deleted","branch_kept_reason"}`.
`worktree` is `null` when none was found, `terminal_removed` is true once the
terminal's hc record is removed (a live one is killed first), and
`branch_kept_reason` is `null` once the branch is deleted.

### Exit codes

| code | `start` | `close` |
|---|---|---|
| 0 | started, task sent | closed (the branch may be kept; see the JSON) |
| 1 | git or hc failed after work started; leftovers are printed with the commands to remove them | git or hc failed midway; close again to finish |
| 2 | usage error, including a bad label or a TTY or empty stdin | usage error, including a branch checked out outside its `.worktrees/<slug>` |
| 3 | no `origin`, a failed fetch, or the base missing on `origin` | dirty worktree; nothing touched |
| 4 | missing git repo, `hc` (or a failing `hc ls` or `hc templates`), the template, or a live parent | missing git repo or `hc` |
| 5 | the branch, worktree path or live hc name already exists; pick another branch | no worktree, no labelled terminal and no local branch |
| 6 | started, but hc didn't deliver the task (`task_sent: false`, for example a trust dialog); the terminal and worktree are kept: read its screen, then send the task yourself | - |
| 130 | interrupted | interrupted |

After `start` exits 2 to 5, nothing was created.

See `herdr-subagent --help` for every flag and the tips for agents.
