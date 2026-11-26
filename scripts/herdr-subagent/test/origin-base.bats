#!/usr/bin/env bats
# `start` fetches the base from origin and creates the new branch from
# origin/<base>. Local branches are never written. Real git, local bare origin.

load test_helper

setup() {
	setup_sandbox
}

# Push a commit to origin/$1 (default main) from a second clone, so the repo
# falls behind. Prints the new SHA.
advance_origin() {
	local other="$SANDBOX/other" base="${1:-main}"
	[ -d "$other" ] || git clone -q "$SANDBOX/origin.git" "$other" 2>/dev/null
	git -C "$other" fetch -q origin
	git -C "$other" checkout -q -B "$base" "origin/$base"
	printf '%s\n' "$base" >>"$other/upstream.txt"
	git -C "$other" add -A
	git -C "$other" commit -q -m "upstream $base"
	git -C "$other" push -q origin "$base"
	git -C "$other" rev-parse HEAD
}

# Everything start must leave alone: local branches and tags (other than the
# new branch b), and HEAD and status of every worktree outside .worktrees/.
local_state() {
	git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags |
		grep -v '^refs/heads/b '
	git worktree list --porcelain | sed -n 's/^worktree //p' | grep -v '/\.worktrees/' |
		while read -r wt; do
			printf '== %s\n' "$wt"
			git -C "$wt" rev-parse HEAD
			git -C "$wt" symbolic-ref -q HEAD || true
			git -C "$wt" status --porcelain --untracked-files=all -- ':(top,exclude).worktrees'
		done
}

# Run start expecting exit 3 with nothing created and local state unchanged.
assert_exit3() {
	local before
	before="$(local_state)"
	run --separate-stderr "$SCRIPT" start "$@" <<<"task"
	[ "$status" -eq 3 ]
	[ -z "$output" ]
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
	[ "$(local_state)" = "$before" ]
}

@test "a new commit on origin/main is picked up, and local main stays where it was" {
	local_main="$(git rev-parse main)"
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
	[ "$(git rev-parse main)" = "$local_main" ]
	[ ! -f "$REPO/upstream.txt" ]
}

@test "local branches are untouched, even when diverged, dirty or behind" {
	git checkout -q -b develop
	git commit -q --allow-empty -m dev
	git push -q origin develop
	git commit -q --allow-empty -m local-only
	git checkout -q main
	git commit -q --allow-empty -m diverged
	printf 'dirty\n' >untracked.txt
	advance_origin >/dev/null
	up="$(advance_origin develop)"
	before="$(local_state)"
	run --separate-stderr "$SCRIPT" start --base develop --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
	[ "$(local_state)" = "$before" ]
}

@test "--base names a branch on origin; no local copy is needed" {
	git push -q origin main:remote-only
	up="$(advance_origin remote-only)"
	run --separate-stderr "$SCRIPT" start --base remote-only --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
	run git show-ref --verify --quiet refs/heads/remote-only
	[ "$status" -ne 0 ]
}

@test "--base starts from origin's branch even when a tag or local branch has the same name" {
	git branch develop
	git tag develop
	git push -q origin main:develop
	up="$(advance_origin develop)"
	run --separate-stderr "$SCRIPT" start --base develop --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
}

@test "the new branch does not track origin/<base>" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	run git config branch.b.merge
	[ "$status" -ne 0 ]
}

@test "a failing fetch exits 3 with nothing created" {
	git remote set-url origin "$SANDBOX/missing.git"
	assert_exit3 --branch b
	[[ "$stderr" == *"fetch"* ]] || false
}

@test "no origin exits 3 with nothing created" {
	git remote remove origin
	assert_exit3 --branch b
	[[ "$stderr" == *"no origin"* ]] || false
}

@test "a base missing on origin exits 3 with nothing created" {
	git branch local-only
	assert_exit3 --base local-only --branch b
	[[ "$stderr" == *"origin has no branch local-only"* ]] || false
}

@test "an invalid --base exits 2 with nothing created" {
	run --separate-stderr "$SCRIPT" start --base 'a*' --branch b <<<"task"
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "from a linked worktree, the worktree starts from origin/main under the main checkout" {
	git worktree add -q -b other "$SANDBOX/elsewhere" main
	up="$(advance_origin)"
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
	[ ! -e "$SANDBOX/elsewhere/.worktrees" ]
}

@test "--no-base-update is gone" {
	run --separate-stderr "$SCRIPT" start --no-base-update --branch b <<<"task"
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "help start describes origin/<base> and no longer the Base update" {
	run --separate-stderr "$SCRIPT" help start
	[ "$status" -eq 0 ]
	[[ "$output" != *"Base update"* ]] || false
	[[ "$output" != *"--no-base-update"* ]] || false
	[[ "$output" == *"origin/<base>"* ]] || false
	[[ "$output" == *"  3    "*"fetch"* ]] || false
}

@test "Ctrl-C during the fetch exits 130 and creates nothing" {
	cat >"$STUBS/git" <<'STUB'
#!/bin/bash
if [ "$1" = "fetch" ]; then
	kill -INT "$PPID"
	sleep 1
fi
exec /usr/bin/git "$@"
STUB
	chmod +x "$STUBS/git"
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 130 ]
	[ -z "$output" ]
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
}

@test "a taken name exits 5 before anything is fetched" {
	cat >"$STUBS/git" <<STUB
#!/bin/bash
[ "\$1" = "fetch" ] && printf 'fetch\n' >>"$HC_LOG/git-fetch"
exec /usr/bin/git "\$@"
STUB
	chmod +x "$STUBS/git"
	git branch feat/x
	run --separate-stderr "$SCRIPT" start --branch feat/x <<<"task"
	[ "$status" -eq 5 ]
	[ ! -e "$HC_LOG/git-fetch" ]
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
}
