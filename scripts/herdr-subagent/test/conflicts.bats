#!/usr/bin/env bats
# `run` refuses a branch, worktree path or hc name that is already taken.

load test_helper

setup() {
	setup_sandbox
}

@test "an existing local branch exits 5 and creates nothing" {
	git branch feat/x
	run --separate-stderr "$SCRIPT" run --branch feat/x -- "task"
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
	run --separate-stderr "$SCRIPT" run --branch feat/remote -- "task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: remote branch origin/feat/remote"* ]] || false
	assert_nothing_created
}

@test "a branch only on origin but not yet fetched is not a conflict" {
	git clone -q "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
	git -C "$SANDBOX/other" push -q origin main:refs/heads/unseen
	run --separate-stderr "$SCRIPT" run --branch unseen -- "task"
	[ "$status" -eq 0 ]
	[ -d "$REPO/.worktrees/unseen" ]
}

@test "anything at the worktree path exits 5" {
	mkdir -p "$REPO/.worktrees"
	touch "$REPO/.worktrees/feat-y"
	run --separate-stderr "$SCRIPT" run --branch feat/y -- "task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: worktree path $REPO/.worktrees/feat-y"* ]] || false
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git branch --format='%(refname:short)')" = "main" ]
}

@test "feat/x and then feat-x collide on the path and exit 5" {
	run --separate-stderr "$SCRIPT" run --branch feat/x -- "task"
	[ "$status" -eq 0 ]
	rm -f "$HC_LOG"/*
	run --separate-stderr "$SCRIPT" run --branch feat-x -- "task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: worktree path $REPO/.worktrees/feat-x"* ]] || false
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git -C "$REPO/.worktrees/feat-x" rev-parse --abbrev-ref HEAD)" = "feat/x" ]
	run git show-ref --verify --quiet refs/heads/feat-x
	[ "$status" -ne 0 ]
}

@test "a live terminal with the same hc name exits 5" {
	HC_STUB_LS='{"terminals":[{"address":"t1","agent":"zsh","state":"live"},{"address":"t2","name":"feat-login-oauth","state":"live"}]}' run --separate-stderr "$SCRIPT" run --branch feat/login-OAuth -- "task"
	[ "$status" -eq 5 ]
	[[ "$stderr" == *"already exists: live hc terminal named feat-login-oauth"* ]] || false
	assert_nothing_created
}

@test "hc names that only share a prefix are not a conflict" {
	HC_STUB_LS='{"terminals":[{"address":"t2","name":"feat-login-oauth-2","state":"live"},{"address":"t3","name":"x-feat-login-oauth","state":"live"}]}' run --separate-stderr "$SCRIPT" run --branch feat/login-OAuth -- "task"
	[ "$status" -eq 0 ]
	[ "$(hc_arg 4)" = "feat-login-oauth" ]
}

@test "the conflict checks list only live terminals" {
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(cat "$HC_LOG/ls-calls")" = "ls --json" ]
}

@test "an unignored .worktrees/ warns how to ignore it and still succeeds" {
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$output" = "t9z" ]
	[[ "$stderr" == *"warning: .worktrees/ is not ignored"* ]] || false
	[[ "$stderr" == *"echo '.worktrees/' >> .gitignore"* ]] || false
	[ ! -e "$REPO/.gitignore" ]
	[ "$(grep -c worktrees "$REPO/.git/info/exclude")" -eq 0 ]
}

@test "an ignored .worktrees/ gives no warning" {
	printf '.worktrees/\n' >"$REPO/.gitignore"
	# The untracked .gitignore would abort the Base update.
	run --separate-stderr "$SCRIPT" run --no-base-update --branch b -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"not ignored"* ]] || false
}

@test "the ignore check uses the main checkout, even from a linked worktree" {
	printf '.worktrees/\n' >>"$REPO/.git/info/exclude"
	git worktree add -q -b other "$SANDBOX/elsewhere" main
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" run --branch nested -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"not ignored"* ]] || false
}

@test "help run documents exit 5" {
	run --separate-stderr "$SCRIPT" help run
	[ "$status" -eq 0 ]
	[[ "$output" =~ 5\ +branch,\ worktree\ path\ or\ hc\ name\ already\ exists ]] || false
	[[ "$output" == *"pick another name and retry"* ]] || false
}

@test "a failing hc ls exits 4 and creates nothing" {
	HC_STUB_LS_EXIT=3 HC_STUB_LS="" run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"hc ls failed"* ]] || false
	assert_nothing_created
}
