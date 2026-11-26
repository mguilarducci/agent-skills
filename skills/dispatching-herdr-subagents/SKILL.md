---
name: dispatching-herdr-subagents
description: "How to launch and supervise a Herdr subagent. Use when dispatching or supervising a Herdr subagent."
---

Always launch a Herdr subagent with `herdr-subagent run`. Never use `hc run`, `git worktree add` or the native Agent tool for it.

`herdr-subagent` is the script at `../../scripts/herdr-subagent/herdr-subagent.sh`, relative to this skill's directory; call it by that path.

## Launch

```sh
t=$(herdr-subagent run --branch <new-branch> --base <base-branch> -- "<task>")
```

- Long or multi-line task: `--task-file -` with a heredoc instead of `-- "<task>"`.
- Pick the agent: `--harness claude|codex`, `--model <s>`, `--effort <s>`.
- `--json` for machine-readable output; `--dry-run` to see the plan first.

## Wait

- One: `hc wait "$t"`
- Several: `hc wait --children any` (next one) or `hc wait --children all`.

## Inspect and talk

- `hc read "$t" --lines 200` to see what it did.
- `hc send "$t" "<message>"` to answer or redirect it.

## Clean up

`hc kill "$t"`, then `git worktree remove <worktree>` and `git branch -D <branch>`.

For everything else, run `herdr-subagent help run` or `hc <command> --help`.
