---
name: herdr-implement-spec
description: "Implement the result of /to-spec and /to-tickets in code, with Herdr subagents."
disable-model-invocation: true
license: MIT (derived from mattpocock/skills implement-spec; see LICENSE)
---

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.

The goal is the entire spec implemented as one **stack** of pull requests made with `gh stack` (the `github/gh-stack` extension): one PR per ticket, each stacked on the one before it, with the **flow branch** `flow/<name>` at the bottom of the stack. Use `gh stack` for every stack operation; never `gh pr create` or `gh pr merge` for a stacked PR.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

Start every subagent with a fresh context window.

Communication to and from subagents should be sparse. Communicate primarily through **context pointers**: to the spec, tickets, research notes, and previous commits. Don't duplicate information already available via pointers.

**Implementer subagents** are **Herdr subagents**: call the Skill tool with `dispatching-herdr-subagents` before launching any. They run in the background, so launch as many as the **frontier** allows for maximum concurrency. Building runs in parallel; stacking does not: a stack is strictly linear, so only one implementer adds its PR at a time.

## Steps

1. Read the spec and tickets to understand the task graph. Check `gh stack --version` works; if not, tell the user to run `gh extension install github/gh-stack`.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Create the flow branch `flow/<name>` from the default branch and push it. It is the base of the stack: every PR in the stack ends up merging into it. Keep a list of the stack, bottom to top, as `<PR number> <branch>` pairs; it starts empty, and its top is `flow/<name>`.

4. Launch a fresh **implementer subagent** for each ticket, with its own ticket branch and the current top of the stack as its base (`flow/<name>` while the stack is empty). Each implementer subagent:
   - confirms its worktree is based on that branch before starting, and resets onto it if not;
   - calls the Skill tool with `tdd` to build the ticket;
   - reports ready to stack and waits for your turn message, without opening a PR.

5. Once an **implementer subagent** reports ready, give it the turn when no other implementer holds it: send it the current stack list and its top branch. It then:
   - fetches, rebases its branch onto `origin/<top branch>`, resolves conflicts and reruns the tests;
   - pushes its branch: `git push -u origin <ticket-branch>`;
   - stacks its PR on top with `gh stack link --base flow/<name> --remote origin <PR numbers of the stack, bottom to top> <ticket-branch>`, which opens its PR based on the branch below it;
   - writes its PR body to name the ticket and the spec, and sets its `subagent.pr` label;
   - reports the PR number and URL.
   Check with `gh pr view <number> --json baseRefName` that its base is the previous top, add it to the top of the stack list, and give the turn to the next ready implementer.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets, based on the new top of the stack. This allows for maximum concurrency.

7. Once all tickets are stacked, call the Skill tool with `code-review` on the top of the stack against `flow/<name>`. Fix all issues raised by the code review in a single fresh **implementer subagent**, which stacks its PR on top like the others.

8. Mark every PR in the stack ready for review (`gh pr ready <number>`). Resolve each ticket the way the issue tracker closes work, pointing to its PR, and report the stack (`gh stack view`) and the flow branch. Don't merge the stack: the user does, bottom up, with `gh stack merge`.

9. Close all **implementer subagents** (`herdr-subagent close`): this clears their terminals and worktrees, and keeps their branches, which are the PRs' heads until the stack merges.
