# Herdr subagents launch through hc templates

`herdr-subagent start` launches the child with `hc run <template> "<task>"` instead of building the Harness command and prompt itself. The template, a Markdown file in `~/.config/herdr-core/templates/`, holds the Harness, model, effort and permissions (frontmatter `command`) and the child's fixed rules (body). hc already joins the template body and the task into the first message, adds the report-back target (`<hc from="<parent>" reach="hc send <parent> when done or stuck">`), waits for the agent to be ready and records `first_message.sent`. Keeping our own `--harness`, `--model`, `--effort` and prompt assembly would duplicate that, with per-Harness flag quirks.

## Considered options

- Keep building the command in the script (v1): one more layer to maintain, and no readiness check or `first_message` record.
- Script only creates the worktree and the caller runs `hc run`: two calls, and the caller can still get the name, `--cwd` or parent wrong.
- No script, only a skill with the commands: most room for mistakes (main-checkout root, hc name rules, collisions, safe cleanup).

## Consequences

- The script needs a template to exist; it fails with exit 4 when `hc templates` doesn't list it, and never installs one. The repo ships `implementer` and `implementer-codex` to copy or link.
- Permissions live in the template's `command`, which the user owns, so the script still never sets permission flags or reads Harness config.
- Per-launch overrides of model or effort are gone: a different setup is a different template.
