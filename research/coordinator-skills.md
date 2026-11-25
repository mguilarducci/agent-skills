# What other coordinator skills exist, and how do they work?

Research for issue #23 (map #11, "Coordinator skill"). Date: 2026-11-25.

The question: which skills, guides and harness features coordinate agent work (one agent takes a ticket and delegates it to subagents)? How does each one handle **context gathering**, **delegation and briefing**, **escalation to a human vs acting alone**, and the **overall flow**? The last section compares them with `chief-of-staff`.

Versions checked:

- mattpocock-skills `1.3.2`, local plugin copy (`skills/engineering/*`, `skills/in-progress/*`).
- `chief-of-staff` beta copy at `~/.claude/skills/beta___mattpocock-skills__skills__in-progress__chief-of-staff/SKILL.md`.
- obra/superpowers `6.3.0`, local Codex plugin copy (`~/.codex/.tmp/plugins/plugins/superpowers`).
- Anthropic `deep-research` skill, synced copy under `~/.claude/skills/synced/.../deep-research/SKILL.md`.
- openai/codex `main` at `06f334aa4b053023c5b4199dde0ba9c004d64820`.
- Web docs as fetched on 2026-11-25.

Source tags:

- **[cos]**: `chief-of-staff/SKILL.md` and its `agents/openai.yaml`.
- **[mp:<skill>]**: mattpocock-skills `skills/<area>/<skill>/SKILL.md`.
- **[sp:<skill>]**: superpowers `skills/<skill>/SKILL.md` (plus `implementer-prompt.md` where noted).
- **[dr]**: Anthropic `deep-research` SKILL.md.
- **[mars]**: Anthropic, "How we built our multi-agent research system", https://www.anthropic.com/engineering/multi-agent-research-system
- **[bea]**: Anthropic, "Building effective agents", https://www.anthropic.com/engineering/building-effective-agents
- **[cc-sub]**: Claude Code docs, subagents, https://code.claude.com/docs/en/sub-agents
- **[cc-teams]**: Claude Code docs, agent teams, https://code.claude.com/docs/en/agent-teams
- **[cc-tool]**: the Agent tool description as delivered to a Claude Code session on 2026-11-25 (read from this research session's own tool list).
- **[cx-doc]**: Codex docs, subagents, https://learn.chatgpt.com/docs/agent-configuration/subagents (redirected from developers.openai.com/codex/subagents)
- **[cx-src]**: openai/codex `codex-rs/core/src/tools/handlers/multi_agents_spec.rs` at the commit above.

## Answer

There are three layers, and a coordinator skill sits on the top one:

1. **Harness primitives** (Claude Code Agent tool and agent teams, Codex `spawn_agent`). They decide what a subagent starts with, how results come back, and how permission prompts reach the human. Both harnesses forbid a subagent from talking to the human directly in the usual case: prompts bubble up to the parent session.
2. **Guidance** (Anthropic's two engineering posts, the harness tool descriptions). The common rules: brief with objective + output format + sources/tools + boundaries; scale effort to the task; keep context clean by passing references, not content; parallelise only independent work.
3. **Coordinator skills** (`implement-spec`, `wayfinder`, superpowers `subagent-driven-development` and `dispatching-parallel-agents`, Anthropic `deep-research`, `software-factory`). They differ most on **escalation**: from "never wait on a human, rule and ledger it" (superpowers) to "HITL tickets are only resolved with the human" (wayfinder) to "a run never waits; the human re-enters through the tracker" (software-factory).

`chief-of-staff` is the only one that combines delegation with a persistent, dated memory (a wiki) and an explicit "the conversation stays with you" rule. It is thin on mechanics: no task graph, no review gate, no status contract for subagent reports, and no rule for when to stop and ask beyond "every change to your own setup starts as an offer".

## Harness primitives

### Claude Code: Agent tool (subagents)

- **Context gathering.** A non-fork subagent "starts with a fresh, isolated context window. It doesn't see your conversation history, the skills you've already invoked, or the files Claude has already read." It does load its own system prompt, the task message, CLAUDE.md (except Explore, Plan, web-fetch), a git status snapshot, and skills named in its `skills` field. A **fork** "inherits the parent conversation instead of starting fresh." [cc-sub]
- **Delegation and briefing.** The parent picks a subagent type by its `description` ("use proactively" encourages delegation). "Claude composes a delegation message that summarizes the task"; rules that must reach the subagent have to be restated in that message. [cc-sub] The tool description adds: "A fresh agent costs more than it looks. It knows only what you put in the prompt, and you see only the summary it sends back"; brief it "like the peer it is: state the goal and what you have already ruled out, point it at the files and docs worth reading instead of retyping them, and keep the scope explicit and narrow." It also says "Do the work yourself when it is a handful of tool calls", "don't delegate a check you could run inline", and "When in doubt, don't spawn." [cc-tool]
- **Results.** The final report returns to the parent. Background subagents (the default for spawns from the main conversation) "reach Claude as a completion notification in a later turn." Resuming with `SendMessage` keeps the subagent's full history. [cc-sub] The tool description says "Never fabricate or predict a pending agent's results" and the report "is not shown to the user — relay what matters." [cc-tool]
- **Escalation.** `AskUserQuestion` is removed from subagent tools, so a subagent cannot ask the human directly. Permission prompts pass through (foreground) or surface in the main session naming the subagent (background). "A message from an agent doesn't count as your approval for a pending permission prompt." [cc-sub]
- **Other mechanics.** Nesting up to three layers (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`); 20 concurrent by default; `isolation: worktree` gives an isolated repo copy branched from the default branch. [cc-sub]
- **When to delegate.** Main conversation for back-and-forth, shared multi-phase context, quick changes, or when latency matters. Subagents when the task "produces verbose output you don't need in your main context", needs tool restrictions, or "is self-contained and can return a summary." [cc-sub]

### Claude Code: agent teams (experimental)

- **Context.** Teammates load CLAUDE.md, MCP servers and skills like a normal session, plus the spawn prompt; "The lead's conversation history does not carry over." [cc-teams]
- **Delegation.** A shared task list with pending / in progress / completed states and dependencies; teammates self-claim "the next unassigned, unblocked task", with file locking against double claims. A mailbox lets teammates message each other. [cc-teams]
- **Escalation.** The human can talk to any teammate directly. Teammate permission prompts appear in the lead session. A teammate's plan approval goes to the lead, and is auto-approved unless the teammate's mode was changed. Agent messages never count as human consent. [cc-teams]
- **Guidance.** "Start with 3-5 teammates"; "5-6 tasks per teammate"; "Avoid file conflicts"; the lead sometimes "starts implementing tasks itself instead of waiting for teammates"; "Letting a team run unattended for too long increases the risk of wasted effort." Use subagents "for sequential tasks, same-file edits, or work with many dependencies." [cc-teams]

### Codex: `spawn_agent` and friends

- **Spawning is opt-in.** "Do not spawn sub-agents unless the user or applicable AGENTS.md/skill instructions explicitly ask for sub-agents, delegation, or parallel agent work. Requests for depth, thoroughness, research, investigation, or detailed codebase analysis do not count as permission to spawn." [cx-src] The docs say the same: local Codex "delegate[s] when you ask directly" or when `AGENTS.md`/skill instructions request it. [cx-doc] So a coordinator skill is itself the authorisation in Codex.
- **Context.** v1 `fork_context`: "True forks the current thread history into the new agent; false or omitted starts with only the initial prompt." v2 `fork_turns` "Defaults to `all`", with `none` warned as possibly leaving the agent without needed context. [cx-src] Skills, sandbox, permissions, provider and MCP servers are inherited; a custom agent file cannot override sandbox or approval policy. [cx-doc]
- **Delegation guidance** (in the tool description). Plan first, "Identify which tasks are immediate blockers on the critical path, and which tasks are sidecar tasks"; "Do not delegate urgent blocking work"; subtasks "must be concrete, well-defined, and self-contained"; "each delegated task has a disjoint write set"; "Call wait_agent very sparingly"; "Do not redo delegated subagent tasks yourself." [cx-src]
- **Results.** `wait_agent`, `send_input` / follow-up task, `interrupt`, `close_agent` ("Completed agents remain open and count toward the concurrency limit until closed"). [cx-src] Codex "waits until all requested results are available" and returns one consolidated response. [cx-doc]
- **Escalation.** Approval requests from background threads appear in the CLI approval overlay with a source label; if a fresh approval cannot be surfaced, the action fails and the error goes back to the parent. [cx-doc]
- **Built-ins.** `default`, `worker` (implementation and fixes), `explorer` (read-heavy). Custom agents are TOML files (`name`, `description`, `developer_instructions`, optional model fields) in `~/.codex/agents/` or `.codex/agents/`. [cx-doc]

## Guidance

### Anthropic: multi-agent research system

- **Context gathering.** The lead "analyzes it, develops a strategy, and spawns subagents"; it uses extended thinking to judge complexity and pick subagent count and roles. It saves its plan to memory to survive context truncation past 200K tokens. [mars]
- **Briefing.** Short briefs caused duplicated work and gaps. Each subagent needs "an objective, an output format, guidance on the tools and sources to use, and clear task boundaries." [mars]
- **Effort scaling.** Simple fact-finding: 1 agent, 3-10 tool calls. Comparisons: 2-4 subagents, 10-15 calls each. Complex research: 10+ subagents with divided responsibilities. 3-5 subagents in parallel. [mars]
- **Results.** Subagents act as filters and return condensed findings; the lead decides whether to do another round; a citation pass runs last. Writing outputs to external storage and passing "lightweight references" reduces information loss. [mars]
- **Escalation.** No human in the loop during a run; humans submit the query and receive the result. Observed failures: 50 subagents for a simple query, endless searching, duplicated work, synchronous waits that block steering. [mars]

### Anthropic: building effective agents

- **Orchestrator-workers** suits "complex tasks where you can't predict the subtasks needed"; unlike parallelisation, the orchestrator decides the subtasks from the input. [bea]
- **Escalation.** "Agents can then pause for human feedback at checkpoints or when encountering blockers." Add stopping conditions "such as a maximum number of iterations"; test in sandboxes with guardrails because autonomy compounds errors. [bea]

## Coordinator skills

### mattpocock-skills `implement-spec`

- **Context gathering.** Read the spec and tickets as a **task graph** with a **frontier**. Optionally an **exploration subagent** writes notes to a directory outside the repo "accessible by all future subagents". [mp:implement-spec]
- **Delegation and briefing.** "Start every subagent with a fresh context window." "Communication to and from subagents should be sparse. Communicate primarily through **context pointers**." One background **implementer subagent** per ticket, each in its own worktree and branch, calling `tdd`; a **merger subagent** merges into the integration branch; a final `code-review` and one fix subagent. [mp:implement-spec]
- **Escalation.** None stated. The human is only involved before (spec and ticket approval in `to-spec` / `to-tickets`, which quizzes the user on the breakdown [mp:to-tickets]) and after (draft PR ready for review).
- **Flow.** read graph -> explore (optional) -> integration branch (+ draft PR) -> implementers on the frontier -> merger -> refill frontier -> code review -> fix -> close tickets -> clean worktrees. [mp:implement-spec]

### mattpocock-skills `wayfinder`

- **Context gathering.** Load the map (low-res index) once; "Zoom as needed" into ticket bodies; call skills named in the map's Notes. [mp:wayfinder]
- **Delegation.** Research tickets go to a fresh subagent calling `research`, findings on a throwaway `research/<name>` branch, "Push the branch but open no PR". [mp:wayfinder]
- **Escalation.** Each ticket is **HITL** or **AFK**. Research is AFK; prototype and grilling are HITL and "only resolve through that live exchange; the agent never stands in for the human's side of it". Task tickets are AFK where possible, else a precise checklist for the human. [mp:wayfinder]
- **Flow.** Claim (assign first) -> resolve by type -> resolution comment, close, append to Decisions so far -> graduate fog into new tickets. "Never resolve more than one ticket per session", except research. [mp:wayfinder]

### mattpocock-skills `to-tickets`, `implement`, `retro`, `software-factory`, `loop-me`

- `to-tickets` produces the task graph a coordinator consumes: vertical slices "sized to fit in a single fresh context window", blocking edges, `ready-for-agent` label; the user approves the breakdown first. [mp:to-tickets]
- `implement` is the single-agent baseline: fetch the ticket, "If the reference is ambiguous, ask", `tdd`, `code-review`, commit. [mp:implement]
- `retro` reads session logs and proposes environment changes (navigation, automated checks, coding standards, tool economy, information access), then "Present these candidates to the user". Its reference notes the reviewer has the least **context pressure**, so standards belong to review. [mp:retro]
- `software-factory` (vocabulary, in progress): "A run never waits for a human: it ends, and the human's later change to the ticket tracker or git host triggers a new run." The ticket tracker is "the factory's human interface". Brakes: automated checks, automated review, human review; "cap every loop of runs at a few tries before a human". Each task answers "Where does a human re-enter?" and "What stops two runs doing the same work?" [mp:software-factory]
- `loop-me` defines **checkpoint** (human verify/decide), **push right** ("Do maximal work before involving the human, so they are asked once, late, with everything prepared") and **brief** ("a tight, decision-ready summary ... never the raw output"). [mp:loop-me]

### obra/superpowers `subagent-driven-development`

- **Context gathering.** Work in a worktree; read the plan once, and the spec it names ("the spec is the binding authority"). A pre-flight conflict scan writes a table of cross-task conflicts into a **ledger** file. The ledger (`.superpowers/sdd/<plan>/progress.md`) is the recovery map after compaction: "controllers that lost their place have re-dispatched entire completed task sequences — the single most expensive failure observed." [sp:subagent-driven-development]
- **Delegation and briefing.** A script extracts each task into a brief file; the dispatch carries one line of where the task fits, the brief path, interfaces from earlier tasks, the controller's resolution of ambiguities, and a report-file path. "Do not paste accumulated prior-task summaries" (one real dispatch was 42k chars, 99% history). Implementers never spawn subagents. Implementers run sequentially ("Never dispatch multiple implementation subagents in parallel"). Explicit model selection per role; "Turn count beats token price." [sp:subagent-driven-development]
- **Report contract.** `DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT`. The implementer is told "It is always OK to stop and say 'this is too hard for me.'" and to escalate on architectural choices, missing context or uncertainty. The controller responds with more context, a stronger model, a smaller task, or a ruling. [sp:implementer-prompt.md]
- **Review gate.** A task reviewer per task (spec + quality, diff handed over as a file), a fix loop capped at 5 rounds (rounds 1-3 resume the implementer, 4-5 a fresh one on a stronger model), then a breaker where the controller adjudicates. The controller never fixes code itself. A final whole-branch review on the strongest model. [sp:subagent-driven-development]
- **Escalation.** "Rulings, not stalls. A running plan does not wait on a human." Every decision is ledgered as `Ruling: <what> — <why> — <what it costs if wrong>` and listed in the final message under "Rulings I made". Only four things stop it: irreversible or destructive operations, security-sensitive actions, side effects outside the worktree (merge, push to a shared branch, publish), or a plan so broken every path is a guess. No "Should I continue?" check-ins. [sp:subagent-driven-development]

### obra/superpowers `dispatching-parallel-agents`

- One agent per independent problem domain, all dispatched in one response. Each brief: specific scope, clear goal, constraints, expected output. Do not use when failures are related or agents would share state. After return: read summaries, check for conflicts, run the full suite, spot-check. No human escalation step. [sp:dispatching-parallel-agents]

### Anthropic `deep-research` skill

- **Role.** "You are acting as the **coordinator**." It never researches or writes files itself, and does not even read the researcher or writer instructions, "to keep your context clean". [dr]
- **Context gathering.** Ask follow-up questions only for ambiguity that "would meaningfully impact how research is conducted". [dr]
- **Delegation.** Decompose into mutually exclusive, collectively exhaustive subtopics; a table maps query shape to researcher count (default 3). Fixed brief template: topic, objective, key questions, suggested sources, constraints, output path, and "read references/researcher.md first". All researchers spawn in parallel, then one writer subagent. [dr]
- **Escalation and stopping.** At most one extra research round ("This step can only be followed once"). No human checkpoint after the initial questions. Delivers a 3-5 sentence summary plus the report path. [dr]

## Comparison with `chief-of-staff`

What `chief-of-staff` does [cos]:

- Delegates every task to a background subagent with a fresh context; "the conversation stays with you" (questions, interviews, check-ins happen in the coordinator session).
- Briefs with **context pointers** plus goal, what is ruled out, and scope.
- Relays results outcome-first, adding detail "only when it changes what they would do".
- Routes large work through `to-spec` -> `to-tickets` -> `implement-spec`; runs `retro` on about one in five subagent sessions, decides itself which candidates to pursue.
- Keeps a dated wiki (index, one page per thing, ingest / query / lint, history not present tense).
- After friction, offers environment changes; "Every change to your own setup and tools starts as an offer."
- Manual-only (`disable-model-invocation: true`, `allow_implicit_invocation: false`).

| Concern | chief-of-staff | Closest other source | Gap or difference |
| --- | --- | --- | --- |
| Context gathering | Query the wiki before deciding or briefing | superpowers ledger; Anthropic plan-in-memory | No step that reads the ticket and decomposes it; no pre-flight conflict scan |
| Briefing | Context pointers + goal, ruled out, scope | Claude Code tool text (same shape); Anthropic adds output format and sources; superpowers adds brief and report files | No output format or report contract |
| Results | Outcome-first relay to the user | superpowers status codes; deep-research short summary + path | No defined report shape, no review gate between subagent and user |
| Escalation | Human talks only to the coordinator; setup changes are offers | superpowers "rulings, not stalls" with four stop classes; wayfinder HITL/AFK; loop-me push right | No stated rule for when to decide alone vs ask; no ledger of rulings made for the human |
| Parallelism | Not addressed | implement-spec frontier; Codex disjoint write sets; teams 3-5 | No rule on concurrency or file conflicts |
| Memory | Dated wiki across sessions | superpowers ledger (per plan, deleted at end); Anthropic memory (per run) | Unique: the only cross-session memory |
| Improvement loop | Retro on ~1 in 5 sessions; friction -> offer | retro skill; software-factory brakes | Unique among coordinators |
| Harness fit | Harness-neutral | Codex requires explicit authorisation to spawn | The skill text itself must authorise delegation for Codex to spawn |

Takeaways for a v1 coordinator that starts from a ticket:

- Harness rules already settle that subagents do not ask the human; the coordinator is the only channel (Claude Code removes `AskUserQuestion`; Codex surfaces approvals to the parent). `chief-of-staff` matches this.
- The sources that do ticket work (implement-spec, superpowers) add a report contract and a review gate; `chief-of-staff` has neither.
- The open design choice is escalation style: superpowers decides and ledgers, wayfinder and loop-me ask (late, once, with a brief), software-factory ends the run and lets the tracker carry the question.
