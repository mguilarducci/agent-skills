---
name: herdr-implement-spec
description: "Implement the result of /to-spec and /to-tickets in code, with Herdr subagents."
disable-model-invocation: true
license: MIT (derived from mattpocock/skills implement-spec; see LICENSE)
---

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, tell the user to run `/setup-matt-pocock-skills`.

The goal is the entire spec implemented as one **stack** of pull requests made with `gh stack` (the `github/gh-stack` extension): one PR per ticket, each stacked on the one before it, with the **flow branch** `flow/<name>` at the bottom of the stack. Use `gh stack` for every stack operation; never `gh pr create` for a stacked PR. Nobody merges anything: neither you nor any subagent merges a branch or a PR. The work ends with the stack built.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

Start every subagent with a fresh context window.

Communication to and from subagents should be sparse. Communicate primarily through **context pointers**: to the spec, tickets, research notes, and previous commits. Don't duplicate information already available via pointers.

**Implementer subagents** are **Herdr subagents**: call the Skill tool with `dispatching-herdr-subagents` before launching any. They run in the background, so launch as many as the **frontier** allows for maximum concurrency. Building runs in parallel; stacking does not: a stack is strictly linear, so only one implementer adds its PR at a time.

## Steps

1. Read the spec and tickets to understand the task graph. Check `gh stack --version` works; if not, tell the user to run `gh extension install github/gh-stack`.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Create the flow branch `flow/<name>` from the default branch and push it. It is the base of the stack: the bottom PR is based on it. Keep a list of the stack, bottom to top, as `<PR number> <branch>` pairs; it starts empty, and its top is `flow/<name>`.

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
   Check with `gh pr view <number> --json baseRefName` that its base is the previous top, add it to the top of the stack list, close the implementer (`herdr-subagent close <ticket-branch>`, which keeps its branch), and give the turn to the next ready implementer.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets, based on the new top of the stack. This allows for maximum concurrency.

7. Once all tickets are stacked, call the Skill tool with `code-review` on the top of the stack against `flow/<name>`. Fix all issues raised by the code review in a single fresh **implementer subagent**, based on the top of the stack. It opens no PR and stacks nothing: each fix goes in the existing PR where the issue is. Tell it in its task that it may switch between the stack's branches in its own worktree. It:
   - adopts the stack locally: `gh stack init --base flow/<name> <stack branches, bottom to top>`;
   - for each issue, checks out that PR's branch (`gh stack checkout <branch>`) and commits the fix there;
   - after each fix, updates the branches above it with `gh stack rebase --upstack`;
   - pushes the stack with `gh stack push --remote origin` and reports which PR got each fix.

8. Mark every PR in the stack ready for review (`gh pr ready <number>`). Resolve each ticket the way the issue tracker closes work, pointing to its PR, and report the stack (`gh stack view`) and the flow branch.

9. Close any **implementer subagent** still open, including the code-review fixer (`herdr-subagent close`): this clears their terminals and worktrees, and keeps their branches, which are the PRs' heads.
