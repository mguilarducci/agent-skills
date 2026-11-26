#!/usr/bin/env bats
# `start` refuses a branch, worktree path or hc name that is already taken.

load test_helper

setup() {
	setup_sandbox
}

@test "an existing local branch exits 5 and creates nothing" {
	git branch feat/x
	run --separate-stderr "$SCRIPT" start --branch feat/x <<<"task"
	[ "$status" -eq 5 ]
	[ -z "$output" ]
	[[ "$stderr" == *"already exists: local branch feat/x"* ]] || false
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git branch --format='%(refname:short)' | sort | tr '\n' ' ')" = "feat/x main " ]
}

@test "an origin/<branch> known locally exits 5 without fetching" {
	git branch feat/remote
	git push -q origin feat/remote
	git branch -D -q feat/remote
	git show-ref --verify --quiet refs/remotes/origin/feat/remote
	# Hide the remote so any fetch would fail loudly.
	mv "$SANDBOX/origin.git" "$SANDBOX/origin.gone"
	run --separate-stderr "$SCRIPT" start --branch feat/remote <<<"task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: remote branch origin/feat/remote"* ]] || false
	assert_nothing_created
}

@test "a branch only on origin but not yet fetched is not a conflict" {
	git clone -q "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
	git -C "$SANDBOX/other" push -q origin main:refs/heads/unseen
	run --separate-stderr "$SCRIPT" start --branch unseen <<<"task"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.worktrees/unseen" ]
}

@test "anything at the worktree path exits 5" {
	mkdir -p "$REPO/.worktrees"
	touch "$REPO/.worktrees/feat-y"
	run --separate-stderr "$SCRIPT" start --branch feat/y <<<"task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: worktree path $REPO/.worktrees/feat-y"* ]] || false
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git branch --format='%(refname:short)')" = "main" ]
}

@test "feat/x and then feat-x collide on the path and exit 5" {
	run --separate-stderr "$SCRIPT" start --branch feat/x <<<"task"
	[ "$status" -eq 0 ]
	rm -f "$HC_LOG"/*
	run --separate-stderr "$SCRIPT" start --branch feat-x <<<"task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: worktree path $REPO/.worktrees/feat-x"* ]] || false
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git -C "$REPO/.worktrees/feat-x" rev-parse --abbrev-ref HEAD)" = "feat/x" ]
	run git show-ref --verify --quiet refs/heads/feat-x
	[ "$status" -ne 0 ]
}

@test "a live terminal with the same hc name exits 5" {
	HC_STUB_LS='{"terminals":[{"address":"t1","agent":"zsh","state":"live"},{"address":"t2","name":"feat-login-oauth","state":"live"}]}' run --separate-stderr "$SCRIPT" start --branch feat/login-OAuth <<<"task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: live hc terminal named feat-login-oauth"* ]] || false
	assert_nothing_created
}

@test "hc names that only share a prefix are not a conflict" {
	HC_STUB_LS='{"terminals":[{"address":"t2","name":"feat-login-oauth-2","state":"live"},{"address":"t3","name":"x-feat-login-oauth","state":"live"}]}' run --separate-stderr "$SCRIPT" start --branch feat/login-OAuth <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_arg 4)" = "feat-login-oauth" ]
}

@test "the conflict checks list only live terminals" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(cat "$HC_LOG/ls-calls")" = "ls --json" ]
}

@test "an unignored .worktrees/ gives no warning and touches no ignore file" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"not ignored"* ]] || false
	[[ "$stderr" != *".gitignore"* ]] || false
	[ ! -e "$REPO/.gitignore" ]
	[ "$(grep -c worktrees "$REPO/.git/info/exclude")" -eq 0 ]
}

@test "help start documents exit 5" {
	run --separate-stderr "$SCRIPT" help start
	[ "$status" -eq 0 ]
	[[ "$output" =~ 5\ +branch,\ worktree\ path\ or\ live\ hc ]] || false
	[[ "$output" == *"pick another --branch and retry"* ]] || false
}

@test "a failing hc ls exits 4 and creates nothing" {
	HC_STUB_LS_EXIT=3 HC_STUB_LS="" run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"hc ls failed"* ]] || false
	assert_nothing_created
}
