---
name: herdr-implement-spec
description: "Implement the result of /to-spec and /to-tickets in code, with Herdr subagents."
disable-model-invocation: true
license: MIT (derived from mattpocock/skills implement-spec; see LICENSE)
---

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.

The goal is the entire spec implemented as one **stack** of pull requests made with `gh stack` (the `github/gh-stack` extension): one PR per ticket, each stacked on the one before it. There is no integration branch: the stack sits directly on the default branch, so the bottom PR, the first ticket's, targets it. Use `gh stack` for every stack operation; never `gh pr create` for a stacked PR. Nobody merges anything: neither you nor any subagent merges a branch or a PR. The work ends with the stack built.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

Start every subagent with a fresh context window.

Communication to and from subagents should be sparse. Communicate primarily through **context pointers**: to the spec, tickets, research notes, and previous commits. Don't duplicate information already available via pointers.

**Implementer subagents** are **Herdr subagents**: call the Skill tool with `dispatching-herdr-subagents` before launching any. They run in the background, so launch as many as the **frontier** allows for maximum concurrency. Building runs in parallel; stacking does not: a stack is strictly linear, so only one implementer adds its PR at a time.

## Steps

1. Read the spec and tickets to understand the task graph. Check `gh stack --version` works; if not, tell the user to run `gh extension install github/gh-stack`.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Launch a fresh **implementer subagent** for each ticket, with its own ticket branch and the current top of the stack as its base. The stack is kept by `gh stack` and shared by every worktree of the clone, so `gh stack view` shows it from anywhere; until the first ticket is stacked, its top is the default branch. Each implementer subagent:
   - confirms its worktree is based on that branch before starting, and resets onto it if not;
   - calls the Skill tool with `tdd` to build the ticket;
   - reports ready to stack and waits for your turn message, without opening a PR.

4. Once an **implementer subagent** reports ready, give it the turn when no other implementer holds it, and tell it the current top branch. Tell it in its task that it may switch branches in its own worktree for this. It then, using `gh stack` and never plain git to switch, rebase or push:
   - puts its branch on top of the stack: for the first ticket, `gh stack init --base <default branch> <ticket-branch>`; otherwise `gh stack checkout <top branch>`, `gh stack add <ticket-branch>` (which adopts its existing branch), then `gh stack checkout <ticket-branch>`;
   - rebases it onto the branch below with `gh stack rebase --remote origin`, resolves conflicts and reruns the tests;
   - opens its PR, ready for review, with `gh stack submit --auto --open --remote origin`;
   - writes its PR body to name the ticket and the spec, and sets its `subagent.pr` label;
   - reports the PR number and URL.
   Check with `gh pr view <number> --json baseRefName,isDraft` that its base is the previous top and that it is not a draft, close the implementer (`herdr-subagent close <ticket-branch>`, which keeps its branch and frees it for the next one), and give the turn to the next ready implementer.

5. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets, based on the new top of the stack. This allows for maximum concurrency.

6. Once all tickets are stacked, call the Skill tool with `code-review` on the top of the stack against the default branch. Fix all issues raised by the code review in a single fresh **implementer subagent**, based on the top of the stack. It opens no PR and stacks nothing: each fix goes in the existing PR where the issue is. Tell it in its task that it may switch between the stack's branches in its own worktree. It:
   - for each issue, checks out that PR's branch (`gh stack checkout <branch>`) and commits the fix there;
   - after each fix, updates the branches above it with `gh stack rebase --upstack`;
   - pushes the stack with `gh stack push --remote origin` and reports which PR got each fix.

7. Resolve each ticket the way the issue tracker closes work, pointing to its PR, and report the stack (`gh stack view`).

8. Close any **implementer subagent** still open, including the code-review fixer (`herdr-subagent close`): this clears their terminals and worktrees, and keeps their branches, which are the PRs' heads.
