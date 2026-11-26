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
The branch on `origin` a Herdr subagent's worktree is created from; `main` unless another is given. `start` fetches it and branches from `origin/<base>`; local branches are never written.
_Avoid_: Source branch, parent branch, Base update (the v1 step that rewrote the local base branch; retired)

**Template**:
An `hc` template a Herdr subagent is started from: a Markdown file whose frontmatter `command` sets the Harness, model, effort and permissions, and whose body holds the child's fixed rules. A different setup is a different Template.
_Avoid_: Preset, profile, harness config

**Close**:
Cleaning up a Herdr subagent: kill and remove its terminal, remove its worktree when it is clean, and delete its branch only once merged into `origin/<base>`. Unmerged work is always kept.
_Avoid_: Cleanup, teardown, kill (that ends only the terminal's program)
