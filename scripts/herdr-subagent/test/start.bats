#!/usr/bin/env bats
# `start` end to end, with hc stubbed on PATH.

load test_helper

setup() {
	setup_sandbox
}

@test "start creates the worktree and launches the template through hc with the exact argv" {
	run --separate-stderr "$SCRIPT" start --branch feat/login-OAuth <<<"Add OAuth login"
	[ "$status" -eq 0 ]

	wt="$REPO/.worktrees/feat-login-OAuth"
	[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "feat/login-OAuth" ]
	[ "$(git -C "$wt" rev-parse HEAD)" = "$(git rev-parse main)" ]

	[ "$(hc_argv)" = "$(printf '%s\n' run --bg --name feat-login-oauth --cwd "$wt" \
		--parent tparent --label "subagent.repo=$REPO" --label subagent.branch=feat/login-OAuth \
		--label subagent.base=main -- implementer 'Add OAuth login')" ]
}

@test "a bare id from hc run is accepted too, though without a first_message" {
	HC_STUB_OUTPUT="t4k" run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 6 ]
	[ "$(printf '%s' "$output" | jq -r .terminal)" = "t4k" ]
}

@test "--flag=value works like --flag value, in any order" {
	git push -q origin main:develop
	run --separate-stderr "$SCRIPT" start --branch=x/one --base=develop <<<"task"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.worktrees/x-one" ]
	run --separate-stderr "$SCRIPT" start --base develop --branch x/two <<<"task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/x-two" rev-parse --abbrev-ref HEAD)" = "x/two" ]
}

@test "start from a linked worktree still lands under the main checkout" {
	git worktree add -q -b other "$SANDBOX/elsewhere" main
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" start --branch nested <<<"task"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.worktrees/nested" ]
	[ ! -e "$SANDBOX/elsewhere/.worktrees" ]
	[ "$(hc_arg 6)" = "$REPO/.worktrees/nested" ]
}

@test "a repo with a separate git dir gets its worktrees under the main checkout" {
	git clone -q --separate-git-dir "$SANDBOX/sep.git" "$SANDBOX/origin.git" "$SANDBOX/sep" 2>/dev/null
	cd "$SANDBOX/sep"
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ -d "$SANDBOX/sep/.worktrees/b" ]
	[ ! -e "$SANDBOX/.worktrees" ]

	# git keeps no record of where that main checkout is, so from a linked
	# worktree the script refuses rather than guess or nest.
	git worktree add -q -b other "$SANDBOX/elsewhere" main
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" start --branch c <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"run it from the main checkout"* ]] || false
	[ ! -e "$SANDBOX/elsewhere/.worktrees" ]
	[ ! -e "$SANDBOX/sep.git/.worktrees" ]
	[ ! -e "$SANDBOX/sep/.worktrees/c" ]
}

@test "hc names match the branch ticket's table" {
	check() {
		rm -f "$HC_LOG"/*
		run --separate-stderr "$SCRIPT" start --branch "$1" <<<"task"
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
	HC_STUB_EXIT=3 HC_STUB_OUTPUT="" run --separate-stderr "$SCRIPT" start --branch feat/x <<<"task"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ -d "$REPO/.worktrees/feat-x" ]
	[[ "$stderr" == *"git worktree remove $REPO/.worktrees/feat-x"* ]] || false
	[[ "$stderr" == *"git branch -d feat/x"* ]] || false
}

@test "cleanup commands quote a worktree path with spaces, so they work when pasted" {
	git clone -q "$SANDBOX/origin.git" "$SANDBOX/my repo" 2>/dev/null
	cd "$SANDBOX/my repo"
	HC_STUB_EXIT=3 HC_STUB_OUTPUT="" run --separate-stderr "$SCRIPT" start --branch feat/x <<<"task"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"git worktree remove '$SANDBOX/my repo/.worktrees/feat-x'"* ]] || false
	printf '%s\n' "$stderr" | sed -n 's/^  \(git .*\)$/\1/p' >"$SANDBOX/cleanup"
	[ "$(wc -l <"$SANDBOX/cleanup" | tr -d ' ')" = "2" ]
	/bin/bash -e "$SANDBOX/cleanup"
	[ ! -e "$SANDBOX/my repo/.worktrees/feat-x" ]
	run git show-ref --verify --quiet refs/heads/feat/x
	[ "$status" -ne 0 ]
}

@test "hc output without a terminal id exits 1 with cleanup commands" {
	HC_STUB_OUTPUT="something odd happened" run --separate-stderr "$SCRIPT" start --branch b <<<"task"
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
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
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
if [ "$1" = templates ]; then
	echo '{"templates":[{"name":"implementer","description":"d","command":"claude"}]}'
	exit 0
fi
if [ "$1" = get ]; then
	echo '{"address":"tparent","state":"live"}'
	exit 0
fi
kill -INT "$PPID"
sleep 1
echo '{"address":"t1"}'
STUB
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 130 ]
	[ -z "$output" ]
	[[ "$stderr" == *"git worktree remove $REPO/.worktrees/b"* ]] || false
}

@test "runs under macOS stock /bin/bash" {
	run --separate-stderr /bin/bash "$SCRIPT" start --branch feat/login-OAuth <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -c '[.terminal, .task_sent]')" = '["t9z",true]' ]
	[ "$(hc_arg 4)" = "feat-login-oauth" ]

	rm -rf "${HC_LOG:?}"/*
	HC_STUB_OUTPUT='{"address":"t1","first_message":{"sent":false,"reason":"blocked (permission)"}}' \
		run --separate-stderr /bin/bash "$SCRIPT" start --branch other <<<"task"
	[ "$status" -eq 6 ]
	[ "$(printf '%s' "$output" | jq -r .reason)" = "blocked (permission)" ]
}
