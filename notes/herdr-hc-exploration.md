# Herdr app + herdr-core (`hc`) exploration notes

> Temporary notes from an exploratory Claude Code session (2026-11-25), run from
> the `hc` worktree of this repo inside a Herdr space. Everything below was
> either read from Herdr's own docs/mod source or verified by running it, and
> each claim says which. Unverified items are marked as such.

## How we explored

- Read `~/.config/herdr-app/AGENTS.md`, which the app rewrites on every start.
- Ran the built-in manuals: `hc --skill`, `hc --help`, `herdr-app --skill`,
  `herdr-app commands`, and `hc <cmd> --help`.
- Read the source of the shipped mods: `mods/worktree/main.js`,
  `mods/spaces/main.js`, `mods/menu/main.js`, `mods/agents/main.js`,
  `mods/tabs/main.js`, and the `herdr.d.ts` typings.
- Ran experiments with `git worktree`, `herdr-app do ...` and `hc run/get/ls/wait/send/kill`,
  inspecting results with `hc get <t> --json` and `herdr-app ls`.
- Measured memory with `ps -o rss` and tokens with `claude -p --output-format json`
  and the subagent usage reports.
- Cleaned up after every experiment (spaces, terminals, worktrees, branches).

## 1. Two programs

- **`herdr-app`**: the window. It owns spaces, tabs, layouts and mods. It is
  driven with `herdr-app do <command> '<json>'` (or `--key value`).
- **herdr-core (`hc`)**: runs every terminal and agent. It only knows
  **terminals with labels**; it has no concept of space or tab.
- The app stores spaces/tabs as a flat list (in a document the core keeps for it)
  and links terminals to them through labels:
  `herdr.space=<id>`, `herdr.tab=<id>`, plus `where` (display text) and
  `herdr.seen` / `herdr.pinned` / `herdr.right-click`.

## 2. How "New worktree" works (mod `worktree`, not the app binary)

The shipped dialog runs these steps (`mods/worktree/main.js`, `create()`):

1. Remote space only: `sh -c 'printf %s "$HOME"'` to find home.
2. Read `worktrees.directory` from `~/.config/herdr-app/settings.json`
   (default `~/.herdr/worktrees`).
3. `git rev-parse --show-toplevel` and
   `git rev-parse --path-format=absolute --git-common-dir` in the space's first
   terminal folder. The repo name comes from the **main** checkout, so a worktree
   made from another worktree still goes under the main repo's folder.
4. `git show-ref --verify --quiet refs/heads/<branch>`.
5. `git worktree add <path> <branch>` if the branch exists, otherwise
   `git worktree add -b <branch> <path> HEAD`, where `HEAD` is the *current*
   checkout, not `main`. Path: `<directory>/<repo>/<slug(branch)>`, and the slug
   turns `/` and other symbols into `-`.
6. `space.new {folder: path}`, left **unnamed** so it follows the folder and nests.

It runs git through the mod API `exec()`, not through `hc`. `hc` is only involved
indirectly, because the space's terminal runs in herdr-core.

There is no CLI command dedicated to worktrees. `mod.open` takes no props, so the
dialog can't be pre-filled from the shell. Doing the steps by hand works (verified).

## 3. Space nesting in the sidebar (mod `spaces`)

- Purely visual, computed in `mods/spaces/main.js` (`ordered()`); the mod also
  calls `space.move` to keep children right after their root.
- Root = a space whose first terminal is in a repo's **main** checkout.
  Child = a space in a **linked** worktree of the same repo.
- **Depth is always 1.** Worktree spaces are never parents, and git worktrees have
  no hierarchy either (all are siblings of the main checkout).
- Without a main-checkout space, worktree spaces show flat (no root).
- Deeper nesting would need a `mod.clone` of `spaces` plus somewhere to store a
  parent relation, because nothing records one.

## 4. `space.new` from `hc`'s point of view

Verified with `hc get <t> --json`. A space created by the app is just a terminal with:

- `argv: ["/bin/zsh","-l"]` (or the given `argv`), `cwd: <folder>`, `keep: true`
- labels `herdr.space`, `herdr.tab`, `where: "<space> / <tab>"`
- `parent: null`

Right after `space.new`, `hc ls` briefly showed the terminal without `where`,
so the app adds labels just after creating it.

`focus: false` on `space.new`/`tab.new` creates it without switching the screen.

## 5. Subagents: Claude Code built-in vs `claude -p` vs `hc`

### Memory (measured, single run)

| what | RSS |
|---|---|
| this interactive session's `claude` process | ~600 MB |
| `claude -p "Reply with just: OK"` peak | ~260 MB (no child processes) |
| built-in subagent (Agent tool), increase of the parent process | ~5 MB |
| interactive `claude` launched via `hc run` | ~450 MB |

Built-in subagents run **in-process** (no new CLI process). Ratio vs `claude -p`: ~50x.

### Tokens for a trivial "oi" (measured)

| type | `claude -p --agent <type>` | built-in subagent |
|---|---|---|
| default / general-purpose / claude | ~23.3k | ~30.3k |
| Explore / Plan | ~19.8k | ~15.3–15.5k |
| claude-code-guide | not available | ~24.4k |
| statusline-setup | ~5.0k | ~9.0k |
| web-fetch | "not found" even though it is listed | ~4.6k |

- Almost all of it is the fixed cost of the system prompt and tool definitions.
  Fewer tools means cheaper.
- `claude -p` cost: ~$0.097 cold (cache write) vs ~$0.005 warm (cache read).
- Custom subagent types: `~/.claude/agents/<name>.md` or `.claude/agents/<name>.md`
  (frontmatter: `name`, `description`, `tools`, `model`; body = system prompt).

### Managing an interactive `claude` via `hc` (verified)

```sh
hc run --bg --name <n> --cwd <dir> \
  claude --model sonnet --allowedTools "Read" "Write" "Bash(hc send:*)" -- \
  "<task> ... report with: hc send $HC_TERMINAL_ID \"<result>\""
hc wait --children any      # wakes on the child's message/status
hc send <n> "follow-up"     # same process, same context
hc read <n> --lines 0       # see its screen
hc kill <n>
```

- Put `--` before the task: `--allowedTools` is variadic and swallows a trailing prompt.
- Pre-allow tools, or it will block on permission prompts (`blocked` status).
- Reports arrive as `<hc from="t2k name">...</hc>`. Verify them; don't trust them blindly.
- The `hc` manual discourages `-p` for agents (not steerable). Interactive is preferred.

## 6. A subagent in its own worktree: options A–D (all verified)

Common step: `git worktree add -b <b> ~/.herdr/worktrees/<repo>/<b> HEAD`.

| option | how | own space/tab | `parent` (wait --children, dies with me) | notes |
|---|---|---|---|---|
| **A** | `hc run --cwd <worktree>` | no, sub-agent of my tab | yes | simplest |
| **B** | `herdr-app do space.new {folder, argv, task}` | own **space** | **no** (`parent: null`) | `task` is appended to `argv`; end argv with `"--"`. Report tag has no name |
| **C** | `hc run` + `--label herdr.space=<new id> --label herdr.tab=<new id>` | own **space** (adopted) | yes | also listed as my sub-agent |
| **D** | `hc run` + `--label herdr.space=<my space id> --label herdr.tab=<new id>` | new **tab** in my space | yes | tab is named by its number |

Findings:

- The app adopts any terminal carrying `herdr.space`/`herdr.tab`. Unknown ids
  become a new space or tab.
- **Any string works as an id.** Both `tb<32 hex>` and `tb-sub-d2` were adopted.
  This is undocumented and could break on an update.
- `tab.rename {id, name}` works, for example `"[2] sub-d1"`. The number is static text and
  doesn't follow reordering. The tab bar (`mods/tabs/main.js`) shows only the name.
- Closing the space of a C-style child kills it asynchronously (exit 129, SIGHUP).
  Its `where` then falls back to the parent's tab. Killing a D-style child closes
  its pane and the now-empty tab.
- Custom labels are free-form `key=value`. Avoid `herdr.*` and `where`, and use your
  own prefix (for example `mg.batch=demo`). Filter with `hc ls --label k=v`.
- Related flags: `--outlive-parent` keeps the child alive after the parent ends.
  `--no-parent` drops the parent link. `--parent <t>` sets another parent.
  `--keep` brings back a shell if the program is lost.

## 7. Other machines (not tested: `hc machine ls` was empty)

- `hc machine add <user@host> --name vps`, then `--on vps` on `run`/`exec`/`file`.
- The worktree has to be created remotely (`hc exec --on vps ... git worktree add`).
  It starts from the remote repo's HEAD, so push/fetch first.
- Address children as `vps/t3`. Label ids are local to that machine (no prefix).
- Open questions: whether `hc send t2h` from the remote reaches the local parent,
  and whether parent-lifetime rules apply across cores.

## 8. Naming sub-agents in the agents list (idea, not built)

- The `agents` mod shows `k.name || k.template || k.program?.name || k.address`
  (`mods/agents/main.js:207`).
- `hc run --name` allows only 1–32 chars of `a-z 0-9 - _`, so `2:sub-d1 <branch>`
  is impossible without a mod. The closest is `--name 2-sub-d1`.
- The exact format needs a `mod.clone` of `agents` that renders
  `${tabIndex}:${name} ${branch}`, using the agent's `tab` id, `spaces()` tabs,
  and a label such as `mg.branch` read via `terminals()`.
