# agent-skills

Tools for launching and supervising coding agents from inside Herdr.

## Contributing

Dev tools (bats, shellcheck, shfmt) are pinned in `mise.toml`:

```sh
mise trust && mise install
```

## herdr-subagent

Launches a Herdr subagent from an `hc` template, in a new worktree on a new branch.

### Install

```sh
ln -s "$PWD/scripts/herdr-subagent/herdr-subagent.sh" ~/.local/bin/herdr-subagent
```

### Usage

Run it from a Herdr terminal, inside a git repo:

```sh
t=$(herdr-subagent start --branch feat/login <<'EOF' | jq -r .terminal
Add OAuth login.
EOF
)
hc wait "$t"
```

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

  `implementer` runs Claude Code and `implementer-codex` runs Codex. A
  missing template exits 4 and creates nothing.
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

### Exit codes

- `0`: launched.
- `1`: git or hc failed after work started; the leftovers (worktree, branch)
  are printed with the commands to remove them.
- `2`: usage error, including a TTY or empty stdin.
- `3`: no `origin`, a failed fetch, or the base missing on `origin`.
- `4`: missing git repo, `hc` (or a failing `hc ls` or `hc templates`), the
  template, or a live parent.
- `5`: the branch, worktree path or hc name already exists. Pick another name
  and retry.
- `6`: started, but hc didn't deliver the task (`task_sent: false`, for
  example a trust dialog). The terminal and worktree are kept: read its
  screen, then send the task yourself.
- `130`: interrupted.

After exits 2 to 5, nothing was created.

See `herdr-subagent help start` for every flag.
