# agent-skills

Tools for launching and supervising coding agents from inside Herdr.

## Contributing

Dev tools (bats, shellcheck, shfmt) are pinned in `mise.toml`:

```sh
mise trust && mise install
```

## herdr-subagent

Launches a Claude Herdr subagent through `hc`, in a new worktree on a new branch.

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
- stdout is only the Herdr subagent's terminal id; progress and a summary with
  the next `hc` commands go to stderr.

See `herdr-subagent help run` for every flag and exit code.
