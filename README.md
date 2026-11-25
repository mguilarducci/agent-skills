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
- `--task-file <path|->`: read the task from a file, or from stdin with `-`,
  instead of after `--`. Handy for long or multi-line prompts:

  ```sh
  herdr-subagent run --branch fix/docs --task-file - <<'EOF'
  Fix the "quoted" $HOME and `backtick` bits in the docs.
  EOF
  ```

- stdout is only the Herdr subagent's terminal id; progress and a summary with
  the next `hc` commands go to stderr.
- `--json`: stdout is one JSON object instead,
  `{"terminal","name","branch","base","worktree","harness","model"}`, with
  `model` set to `null` when `--model` is left out.

See `herdr-subagent help run` for every flag and exit code.
