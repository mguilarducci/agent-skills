---
name: dispatching-herdr-subagents
description: "How to launch and supervise a Herdr subagent. Use when dispatching or supervising a Herdr subagent."
---

Always start and close a Herdr subagent with `herdr-subagent`. Never use `hc run`, `git worktree add` or the native Agent tool for it.

`herdr-subagent` is the script at `../../scripts/herdr-subagent/herdr-subagent.sh`, relative to this skill's directory; call it by that path.

## Start

```sh
herdr-subagent start --branch <new-branch> --base <base-branch> <<'EOF'
<task: the issue, the files, how to verify, where to open the PR>
EOF
```

- The branch is created from `origin/<base>`, so push the base first.
- Pick the agent with `--template implementer-claude|implementer-codex`.
- Keep the `terminal` from the JSON it prints.

## Wait

`hc wait --children any`: returns on a child's next report, block, error or exit.

## Inspect and talk

- `hc read <t>` to see its screen.
- `hc send <t> "<message>"` to answer or redirect it.
- `hc keys <t> enter` to clear a dialog it is stuck on.

Treat a report as claims: check the worktree (`git log`, `git diff`, the tests) before relying on it.

## Close

`herdr-subagent close <branch>` once its work is merged into `origin/<base>`.

For everything else, run `herdr-subagent --help`.
