# Herdr subagents launch through hc templates

`herdr-subagent start` launches the child with `hc run <template> "<text>"` instead of building the Harness command itself. The template, a frontmatter-only Markdown file in `~/.config/herdr-core/templates/` named `<role>-<harness>`, holds the Harness, model, effort and permissions (frontmatter `command`). The text is the role's fixed rules from `rules/<role>.md` next to the script, then a `Task:` heading and the task. hc sends that text as the first message, adds the report-back target (`<hc from="<parent>" reach="hc send <parent> when done or stuck">`), waits for the agent to be ready and records `first_message.sent`. Keeping our own `--harness`, `--model`, `--effort` and prompt assembly would duplicate that, with per-Harness flag quirks.

## Considered options

- Keep building the command in the script (v1): one more layer to maintain, and no readiness check or `first_message` record.
- Script only creates the worktree and the caller runs `hc run`: two calls, and the caller can still get the name, `--cwd` or parent wrong.
- No script, only a skill with the commands: most room for mistakes (main-checkout root, hc name rules, collisions, safe cleanup).

## Consequences

- The script needs a template to exist; it fails with exit 4 when `hc templates` doesn't list it, and never installs one. The repo ships `implementer-claude` and `implementer-codex` to copy or link.
- Permissions live in the template's `command`, which the user owns, so the script still never sets permission flags or reads Harness config.
- Per-launch overrides of model or effort are gone: a different setup is a different template.
- The fixed rules live once per role in `rules/<role>.md`, not in each template's body: hc has no include for templates, and one body per Harness would drift. A role with no rules file sends the task alone. `rules/` sits outside `templates/` so linking `templates/*.md` into hc never picks up a frontmatter-less file.
