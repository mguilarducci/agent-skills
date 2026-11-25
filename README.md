# agent-skills

Tools for launching and supervising coding agents from inside Herdr.

## Contributing

Dev tools (bats, shellcheck, shfmt) are pinned in `mise.toml`:

```sh
mise trust && mise install
```

## herdr-subagent

Launches a Claude or Codex Herdr subagent through `hc`, in a new worktree on a new branch.

### Install

```sh
ln -s "$PWD/scripts/herdr-subagent/herdr-subagent.sh" ~/.local/bin/herdr-subagent
```

### Usage

Run it from a Herdr terminal, inside a git repo:

```sh
t=$(herdr-subagent run --branch feat/login -- "Add OAuth login")
hc wait "$t"
```

- `--branch <name>` (required): the new branch. The worktree goes to
  `<main-checkout-root>/.worktrees/<slug(branch)>`.
- `--base <branch>`: the local branch to start from (default `main`).
- `--harness claude|codex`: the agent to start (default `claude`). Codex runs
  as `codex --no-daemon`.
- `--model <s>`, `--effort <s>`: passed to the harness as-is (Codex gets
  `-m <s>` and `-c model_reasoning_effort=<s>`). Left out, your harness config
  applies.
- Base update: before creating the worktree, it fetches `origin` and brings
  the base branch up to date with `origin/main`, in the worktree that has it
  checked out (`main` is fast-forwarded; any other base gets `origin/main`
  merged in). If that can't complete cleanly (uncommitted changes, a diverged
  `main`, a conflicting merge, a failed fetch), it exits 3, changes nothing and
  creates nothing. `--no-base-update` skips it.
- stdout is only the Herdr subagent's terminal id; progress and a summary with
  the next `hc` commands go to stderr.

- An existing branch, worktree path or live hc name is never reused: `run`
  exits 5 before creating anything. Pick another name and retry.

See `herdr-subagent help run` for every flag and exit code.
