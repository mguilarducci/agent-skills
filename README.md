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
- `--base <branch>`: the Base branch, an existing local branch to start from
  (default `main`).
- `--harness claude|codex`: the Harness, the agent program to start (default
  `claude`). Codex runs as `codex --no-daemon`.
- `--model <s>`, `--effort <s>`: passed to the harness as-is (Codex gets
  `-m <s>` and `-c model_reasoning_effort=<s>`). Left out, your harness config
  applies.
- Base update: before creating the worktree, it fetches `origin` and brings
  the Base branch up to date with `origin/main`, in the worktree that has it
  checked out (`main` is fast-forwarded; any other Base branch gets
  `origin/main` merged in). If that can't complete cleanly (uncommitted or
  untracked changes where the Base branch is checked out, a Base branch other
  than `main` checked out nowhere, a diverged `main`, a conflicting merge, a
  failed fetch), it exits 3, changes nothing and creates nothing. The first
  two abort even when the Base branch already has `origin/main`.
  `--no-base-update` skips it.
- `--task-file <path|->`: read the task from a file, or from stdin with `-`,
  instead of after `--`. The task is passed byte-for-byte, trailing newlines
  included; an empty or whitespace-only task exits 2. Handy for long or
  multi-line prompts:

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
- `-n`, `--dry-run`: runs nothing that changes state, not even `git fetch`,
  and prints the plan on stdout instead: one shell-quoted command per line
  (the Base update, `git worktree add` and the full `hc run`), each ready to
  paste into a shell. Arguments, prerequisites and name conflicts are still
  checked (exits 2, 4 and 5); otherwise it exits 0. The Base update lines are
  worked out from local state: they show the step `run` takes if the fetch
  brings new commits to `origin/main`, and known causes of an exit-3 abort
  are noted on stderr. With `--json`, the object has `"terminal": null` and a
  `"commands"` array of those lines:

  ```sh
  herdr-subagent run --dry-run --json --branch fix/ci -- "Fix CI"
  ```

- An existing branch, worktree path or live hc name is never reused: `run`
  exits 5 before creating anything. Pick another name and retry.

### Exit codes

- `0`: launched.
- `1`: git or hc failed after work started; the leftovers (worktree, branch)
  are printed with the commands to remove them.
- `2`: usage error.
- `3`: the Base update could not complete cleanly.
- `4`: missing git repo, `hc` (or a failing `hc ls`), the chosen Harness or
  `$HC_TERMINAL_ID`.
- `5`: the branch, worktree path or hc name already exists. Pick another name
  and retry.
- `130`: interrupted.

After exits 2 to 5, nothing was created.

See `herdr-subagent help run` for every flag.
