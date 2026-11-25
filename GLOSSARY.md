# Agent skills

Tools for launching and supervising coding agents from inside Herdr.

## Language

**Herdr subagent**:
A coding agent launched through `hc` as a child of the current terminal, working in its own worktree.
_Avoid_: Sub, hc subagent, worker

**Native subagent**:
A subagent the harness runs in its own process (for example Claude Code's Agent tool), with no `hc` terminal of its own.
_Avoid_: Normal subagent, built-in subagent

**Harness**:
The agent program a Herdr subagent runs, such as Claude Code or Codex.
_Avoid_: Agent type, CLI, model

**Cross-harness**:
A Herdr subagent whose harness differs from the parent's harness. It is always launched through `hc`.

**Base branch**:
The branch a Herdr subagent's worktree is created from; `main` unless another is given.
_Avoid_: Source branch, parent branch

**Base update**:
Bringing the base branch up to date with its remote before a Herdr subagent's worktree is created from it.
_Avoid_: Sync, refresh, step 0
