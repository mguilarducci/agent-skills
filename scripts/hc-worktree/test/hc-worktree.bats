#!/usr/bin/env bats
# Drives hc-worktree as a process: a stubbed herdr-app on PATH, a throwaway
# git repo and a throwaway HERDR_APP_HOME. The real window is never reached.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../hc-worktree.sh"

setup() {
	SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/sandbox"
	STUBS="$SANDBOX/stubs"
	APP_LOG="$SANDBOX/app-log"
	mkdir -p "$STUBS" "$APP_LOG" "$SANDBOX/home" "$SANDBOX/app"

	# herdr-app stub: records its argv, prints $APP_STUB_OUTPUT, exits $APP_STUB_EXIT.
	cat >"$STUBS/herdr-app" <<'STUB'
#!/bin/bash
n=0
for a in "$@"; do
	n=$((n + 1))
	printf '%s' "$a" >"$APP_LOG/arg.$n"
done
printf '%s\n' "${APP_STUB_OUTPUT-{\"pane\":\"p1\",\"terminal\":\"t1\"\}}"
exit "${APP_STUB_EXIT:-0}"
STUB
	chmod +x "$STUBS/herdr-app"

	export APP_LOG
	export PATH="$STUBS:/usr/bin:/bin"
	export HOME="$SANDBOX/home"
	export HERDR_APP_HOME="$SANDBOX/app"
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

	REPO="$SANDBOX/myrepo"
	git init -q -b main "$REPO"
	git -C "$REPO" commit -q --allow-empty -m init
	cd "$REPO" || exit 1
}

@test "new branch: worktree from HEAD under the default directory, unnamed space" {
	git checkout -q -b topic
	git commit -q --allow-empty -m topic
	run --separate-stderr "$SCRIPT" feat/login
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME/.herdr/worktrees/myrepo/feat-login" ]
	[ "$(git -C "$output" rev-parse --abbrev-ref HEAD)" = "feat/login" ]
	[ "$(git -C "$output" rev-parse HEAD)" = "$(git rev-parse topic)" ]
	[ "$(cat "$APP_LOG/arg.1")" = "do" ]
	[ "$(cat "$APP_LOG/arg.2")" = "space.new" ]
	[ "$(cat "$APP_LOG/arg.3")" = "{\"folder\":\"$output\",\"machine\":\"\"}" ]
}

@test "existing branch is checked out, not recreated" {
	git branch old
	git commit -q --allow-empty -m newer
	run --separate-stderr "$SCRIPT" old
	[ "$status" -eq 0 ]
	[ "$(git -C "$output" rev-parse HEAD)" = "$(git rev-parse old)" ]
}

@test "from a worktree, the repo name is the main checkout's" {
	git worktree add -q -b other "$SANDBOX/elsewhere"
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" x
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME/.herdr/worktrees/myrepo/x" ]
}

@test "worktrees.directory from settings.json, ~ expanded" {
	printf '{"worktrees":{"directory":"~/wt/"}}' >"$HERDR_APP_HOME/settings.json"
	run --separate-stderr "$SCRIPT" a
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME/wt/myrepo/a" ]
}

@test "relative worktrees.directory exits 4 and creates nothing" {
	printf '{"worktrees":{"directory":"wt"}}' >"$HERDR_APP_HOME/settings.json"
	run --separate-stderr "$SCRIPT" a
	[ "$status" -eq 4 ]
	[ ! -e "$APP_LOG/arg.1" ]
	run ! git show-ref --verify --quiet refs/heads/a
}

@test "--no-focus passes focus false" {
	run --separate-stderr "$SCRIPT" --no-focus b
	[ "$status" -eq 0 ]
	[ "$(cat "$APP_LOG/arg.3")" = "{\"focus\":false,\"folder\":\"$output\",\"machine\":\"\"}" ]
}

@test "slug matches the dialog's" {
	run --separate-stderr "$SCRIPT" ' ção/x+y '
	[ "$status" -eq 0 ]
	[ "$output" = "$HOME/.herdr/worktrees/myrepo/ção-x-y" ]
	[ "$(git -C "$output" rev-parse --abbrev-ref HEAD)" = "ção/x+y" ]
}

@test "outside git exits 4" {
	cd "$SANDBOX/home"
	run --separate-stderr "$SCRIPT" a
	[ "$status" -eq 4 ]
}

@test "usage errors exit 2" {
	run --separate-stderr "$SCRIPT"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" a b
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" --nope a
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" '  '
	[ "$status" -eq 2 ]
}

@test "git failure exits 1 and skips herdr-app" {
	run --separate-stderr "$SCRIPT" main
	[ "$status" -eq 1 ]
	[ ! -e "$APP_LOG/arg.1" ]
}

@test "herdr-app error exits 1 and keeps the worktree" {
	export APP_STUB_OUTPUT='{ "error": "no window" }' APP_STUB_EXIT=1
	run --separate-stderr "$SCRIPT" c
	[ "$status" -eq 1 ]
	[ -d "$HOME/.herdr/worktrees/myrepo/c" ]
	[[ "$stderr" == *"worktree was kept"* ]]
}

@test "--help exits 0" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage:"* ]]
}
