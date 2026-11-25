#!/usr/bin/env bats
# `run` end to end, with hc and claude stubbed on PATH.

load test_helper

setup() {
	setup_sandbox
}

expected_text() {
	# $1 task, $2 worktree path, $3 branch
	printf '%s\n\n%s\n%s\n%s' "$1" \
		"Work only in this worktree ($2, branch $3). Do not start other agents." \
		'Report with hc send tparent "<result or blocker>" when done or stuck, not just to acknowledge.' \
		"Write long answers to a file and send its path."
}

@test "run creates the worktree and launches claude through hc with the exact argv" {
	run --separate-stderr "$SCRIPT" run --branch feat/login-OAuth -- "Add OAuth login"
	[ "$status" -eq 0 ]

	wt="$REPO/.worktrees/feat-login-OAuth"
	[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "feat/login-OAuth" ]
	[ "$(git -C "$wt" rev-parse HEAD)" = "$(git rev-parse main)" ]

	[ "$(cat "$HC_LOG/argc")" -eq 9 ]
	[ "$(hc_arg 1)" = "run" ]
	[ "$(hc_arg 2)" = "--bg" ]
	[ "$(hc_arg 3)" = "--name" ]
	[ "$(hc_arg 4)" = "feat-login-oauth" ]
	[ "$(hc_arg 5)" = "--cwd" ]
	[ "$(hc_arg 6)" = "$wt" ]
	[ "$(hc_arg 7)" = "claude" ]
	[ "$(hc_arg 8)" = "--" ]
	[ "$(hc_arg 9)" = "$(expected_text "Add OAuth login" "$wt" feat/login-OAuth)" ]
}

@test "the parent id in the report text is the literal HC_TERMINAL_ID" {
	# shellcheck disable=SC2016 # $HOME must stay literal
	HC_TERMINAL_ID='vps/t3 $HOME' run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	# shellcheck disable=SC2016
	[[ "$(hc_arg 9)" == *'hc send vps/t3 $HOME "<result or blocker>"'* ]] || false
}

@test "stdout is only the terminal id" {
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$output" = "t9z" ]
}

@test "a bare id from hc run is accepted too" {
	HC_STUB_OUTPUT="t4k" run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$output" = "t4k" ]
}

@test "stderr has the summary, next commands and the Claude warning" {
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"$REPO/.worktrees/b"* ]] || false
	for c in "hc read t9z" "hc send t9z" "hc wait t9z" "hc kill t9z"; do
		[[ "$stderr" == *"$c"* ]] || false
	done
	expected="$(
		cat <<EOF
Claude may ask before each \`hc send\`. To allow it for good, add "Bash(hc send:*)" to permissions.allow in one of:
EOF
	)"
	last4="$(printf '%s\n' "$stderr" | tail -n 4)"
	[ "$(printf '%s\n' "$last4" | head -n 1)" = "$expected" ]
	[[ "$(printf '%s\n' "$last4" | sed -n 2p)" =~ ^\ \ ~/\.claude/settings\.json\ +\(user:\ every\ project\)$ ]] || false
	[[ "$(printf '%s\n' "$last4" | sed -n 3p)" =~ ^\ \ $REPO/\.claude/settings\.json\ +\(project:\ shared,\ committed\)$ ]] || false
	[[ "$(printf '%s\n' "$last4" | sed -n 4p)" =~ ^\ \ $REPO/\.claude/settings\.local\.json\ +\(project:\ only\ you,\ not\ committed\)$ ]] || false
}

@test "--flag=value works like --flag value, in any order" {
	git branch develop
	run --separate-stderr "$SCRIPT" run --branch=x/one --base=develop -- "task"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.worktrees/x-one" ]
	run --separate-stderr "$SCRIPT" run --base develop --branch x/two -- "task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/x-two" rev-parse --abbrev-ref HEAD)" = "x/two" ]
}

@test "--base picks the branch the worktree starts from" {
	git checkout -q -b develop
	git commit -q --allow-empty -m dev
	git checkout -q main
	run --separate-stderr "$SCRIPT" run --base develop --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$(git rev-parse develop)" ]
}

@test "run from a linked worktree still lands under the main checkout" {
	git worktree add -q -b other "$SANDBOX/elsewhere" main
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" run --branch nested -- "task"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.worktrees/nested" ]
	[ ! -e "$SANDBOX/elsewhere/.worktrees" ]
	[ "$(hc_arg 6)" = "$REPO/.worktrees/nested" ]
}

@test "hc names match the branch ticket's table" {
	check() {
		rm -f "$HC_LOG"/*
		run --separate-stderr "$SCRIPT" run --branch "$1" -- "task"
		[ "$status" -eq 0 ]
		[ -d "$REPO/.worktrees/$2" ]
		[ "$(hc_arg 4)" = "$3" ]
	}
	check issue-6 issue-6 issue-6
	check feat/login-OAuth feat-login-OAuth feat-login-oauth
	check fix/v1.2_parser fix-v1.2_parser fix-v1-2_parser
	check feature/very-long-branch-naming-for-oauth feature-very-long-branch-naming-for-oauth feature-very-long-branch-naming
}

@test "a failing hc run exits 1, keeps the worktree and prints cleanup commands" {
	HC_STUB_EXIT=3 HC_STUB_OUTPUT="" run --separate-stderr "$SCRIPT" run --branch feat/x -- "task"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ -d "$REPO/.worktrees/feat-x" ]
	[[ "$stderr" == *"git worktree remove $REPO/.worktrees/feat-x"* ]] || false
	[[ "$stderr" == *"git branch -d feat/x"* ]] || false
}

@test "hc output without a terminal id exits 1 with cleanup commands" {
	HC_STUB_OUTPUT="something odd happened" run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[[ "$stderr" == *"git worktree remove"* ]] || false
}

@test "a failing git worktree add exits 1 and never offers to delete a branch it did not create" {
	cat >"$STUBS/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = worktree ] && [ "${2:-}" = add ]; then
	echo "fatal: stubbed failure" >&2
	exit 128
fi
exec /usr/bin/git "$@"
STUB
	chmod +x "$STUBS/git"
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 1 ]
	[ ! -e "$HC_LOG/argc" ]
	[[ "$stderr" != *"git branch -d"* ]] || false
	run git show-ref --verify --quiet refs/heads/b
	[ "$status" -ne 0 ]
}

@test "Ctrl-C exits 130 and prints what was left behind" {
	cat >"$STUBS/hc" <<'STUB'
#!/bin/bash
if [ "$1" = ls ]; then
	echo '{"terminals":[]}'
	exit 0
fi
kill -INT "$PPID"
sleep 1
echo '{"address":"t1"}'
STUB
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 130 ]
	[ -z "$output" ]
	[[ "$stderr" == *"git worktree remove $REPO/.worktrees/b"* ]] || false
}

@test "runs under macOS stock /bin/bash" {
	run --separate-stderr /bin/bash "$SCRIPT" run --branch feat/login-OAuth -- "task"
	[ "$status" -eq 0 ]
	[ "$output" = "t9z" ]
	[ "$(hc_arg 4)" = "feat-login-oauth" ]
}
