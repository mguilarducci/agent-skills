# Herdr subagent worktrees live in `.worktrees/` inside the repo

`herdr-subagent run` creates each worktree at `<main-checkout-root>/.worktrees/<slug(branch)>`, a fixed path, rather than following herdr-app's worktree dialog (`<worktrees.directory>/<repo>/<slug(branch)>`, default `~/.herdr/worktrees`). Following the dialog would mean parsing `~/.config/herdr-app/settings.json` from shell (a `jq` dependency) and tracking a setting the script doesn't own; a fixed in-repo path keeps the script dependency-free and makes every worktree easy to find from the repo itself.

## Consequences

- Worktrees made by the script and by the app's dialog end up in different folders.
- The script never edits or checks `.gitignore` or `.git/info/exclude`; `--help` tells the caller to ignore `.worktrees/` if it shows up in `git status`, so each repo opts in by ignoring it.
- Linked worktrees always go under the **main** checkout, never nested inside another worktree.
