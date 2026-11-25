#!/usr/bin/env bats
# The Base update: `run` brings the Base branch up to date with origin/main
# before it creates the worktree. Real git, local bare origin.

load test_helper

setup() {
	setup_sandbox
}

# Push a commit to origin/main from a second clone, so the repo falls behind.
# $1 file to write (default upstream.txt), $2 its content. Prints the new SHA.
advance_origin() {
	local other="$SANDBOX/other" file="${1:-upstream.txt}"
	[ -d "$other" ] || git clone -q "$SANDBOX/origin.git" "$other" 2>/dev/null
	git -C "$other" pull -q origin main
	printf '%s\n' "${2:-upstream}" >"$other/$file"
	git -C "$other" add -A
	git -C "$other" commit -q -m "upstream $file"
	git -C "$other" push -q origin main
	git -C "$other" rev-parse HEAD
}

# Everything an abort must leave alone: local refs and tags, and HEAD, index
# and working tree of every worktree. Remote-tracking refs are left out: the
# fetch is the first step and is allowed to move them.
git_state() {
	git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags
	git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r wt; do
		printf '== %s\n' "$wt"
		git -C "$wt" rev-parse HEAD
		git -C "$wt" symbolic-ref -q HEAD || true
		git -C "$wt" status --porcelain --untracked-files=all
		git -C "$wt" diff
		git -C "$wt" diff --cached
	done
}

# Run the script expecting a Base update abort: exit 3, nothing created,
# git state unchanged, and a hint about --no-base-update.
assert_aborts() {
	local before
	before="$(git_state)"
	run --separate-stderr "$SCRIPT" run "$@"
	[ "$status" -eq 3 ]
	[ -z "$output" ]
	[[ "$stderr" == *"--no-base-update"* ]] || false
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git_state)" = "$before" ]
}

@test "main behind origin/main is fast-forwarded before the worktree is created" {
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse main)" = "$up" ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
	[ -f "$REPO/upstream.txt" ]
}

@test "main is fast-forwarded in whichever worktree has it checked out" {
	git checkout -q -b parking
	git worktree add -q "$SANDBOX/main-wt" main
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse main)" = "$up" ]
	[ -f "$SANDBOX/main-wt/upstream.txt" ]
	[ -z "$(git -C "$SANDBOX/main-wt" status --porcelain)" ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
}

@test "main not checked out anywhere is fast-forwarded as a ref" {
	git checkout -q -b parking
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse main)" = "$up" ]
	[ "$(git rev-parse parking)" != "$up" ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
}

@test "a feature Base gets origin/main merged in and the worktree starts from the merge" {
	git checkout -q -b develop
	printf 'dev\n' >dev.txt
	git add dev.txt
	git commit -q -m dev
	dev="$(git rev-parse HEAD)"
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --base develop --branch b -- "task"
	[ "$status" -eq 0 ]
	merged="$(git rev-parse develop)"
	[ "$(git rev-parse "$merged^1")" = "$dev" ]
	[ "$(git rev-parse "$merged^2")" = "$up" ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$merged" ]
	[ -f "$REPO/upstream.txt" ]
	# main is not the Base, so it is left alone.
	[ "$(git rev-parse main)" != "$up" ]
}

@test "branch mergeOptions that keep a merge from committing do not stop the Base update" {
	git checkout -q -b develop
	git commit -q --allow-empty -m dev
	git config branch.develop.mergeOptions "--no-commit --squash"
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --base develop --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse develop^2)" = "$up" ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$(git rev-parse develop)" ]
	run git rev-parse -q --verify MERGE_HEAD
	[ "$status" -ne 0 ]
	[ -z "$(git status --porcelain -- ':(exclude).worktrees')" ]
}

@test "branch mergeOptions that keep a fast-forward from committing do not stop the Base update" {
	git config branch.main.mergeOptions "--squash --no-commit"
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse main)" = "$up" ]
	[ "$(git -C "$REPO/.worktrees/b" rev-parse HEAD)" = "$up" ]
	[ -z "$(git status --porcelain -- ':(exclude).worktrees')" ]
}

@test "a merge that succeeds without bringing in origin/main aborts with exit 3" {
	# A merge that exits 0 but changes nothing, whatever the reason.
	cat >"$STUBS/git" <<'STUB'
#!/bin/bash
[ "${3:-}" = merge ] && [ "${4:-}" = -q ] && exit 0
exec /usr/bin/git "$@"
STUB
	chmod +x "$STUBS/git"
	git checkout -q -b develop
	advance_origin >/dev/null
	assert_aborts --base develop --branch b -- "task"
	[[ "$stderr" == *"does not contain origin/main"* ]] || false
	git checkout -q main
	assert_aborts --branch b -- "task"
}

@test "--no-base-update does no fetch and no merge" {
	git remote set-url origin "$SANDBOX/missing.git"
	before="$(git rev-parse main)"
	run --separate-stderr "$SCRIPT" run --no-base-update --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse main)" = "$before" ]
	[[ "$stderr" != *"Base update"* ]] || false
	[ -d "$REPO/.worktrees/b" ]
}

@test "--no-base-update leaves a stale main stale" {
	advance_origin >/dev/null
	before="$(git rev-parse main)"
	run --separate-stderr "$SCRIPT" run --branch b --no-base-update -- "task"
	[ "$status" -eq 0 ]
	[ "$(git rev-parse main)" = "$before" ]
	[ "$(git rev-parse origin/main)" = "$before" ]
}

@test "unstaged changes in the Base's worktree abort with exit 3" {
	printf 'x\n' >tracked.txt
	git add tracked.txt
	git commit -q -m tracked
	git push -q origin main
	advance_origin >/dev/null
	printf 'dirty\n' >tracked.txt
	assert_aborts --branch b -- "task"
	[[ "$stderr" == *"uncommitted or untracked"* ]] || false
}

@test "staged changes in the Base's worktree abort with exit 3" {
	advance_origin >/dev/null
	printf 'staged\n' >staged.txt
	git add staged.txt
	assert_aborts --branch b -- "task"
}

@test "untracked files in the Base's worktree abort with exit 3" {
	advance_origin >/dev/null
	printf 'new\n' >untracked.txt
	assert_aborts --branch b -- "task"
}

@test "main diverged from origin/main aborts with exit 3" {
	advance_origin >/dev/null
	git commit -q --allow-empty -m local
	assert_aborts --branch b -- "task"
	[[ "$stderr" == *"diverged"* ]] || false
}

@test "main diverged and not checked out anywhere aborts with exit 3" {
	advance_origin >/dev/null
	git commit -q --allow-empty -m local
	git checkout -q -b parking
	assert_aborts --branch b -- "task"
}

@test "a conflicting merge of origin/main into the Base aborts with exit 3" {
	git checkout -q -b develop
	printf 'dev\n' >same.txt
	git add same.txt
	git commit -q -m dev
	advance_origin same.txt upstream >/dev/null
	assert_aborts --base develop --branch b -- "task"
	[[ "$stderr" == *"conflict"* ]] || false
	[ ! -e "$REPO/.git/MERGE_HEAD" ]
}

@test "a failing fetch aborts with exit 3" {
	git remote set-url origin "$SANDBOX/missing.git"
	assert_aborts --branch b -- "task"
	[[ "$stderr" == *"fetch"* ]] || false
}

@test "no origin aborts with exit 3" {
	git remote remove origin
	assert_aborts --branch b -- "task"
	[[ "$stderr" == *"no origin"* ]] || false
}

@test "a non-main Base not checked out anywhere aborts with exit 3" {
	git branch develop
	advance_origin >/dev/null
	assert_aborts --base develop --branch b -- "task"
	[[ "$stderr" == *"not checked out"* ]] || false
}

@test "earlier Herdr subagent worktrees under an unignored .worktrees/ do not count as dirty" {
	run --separate-stderr "$SCRIPT" run --branch first -- "task"
	[ "$status" -eq 0 ]
	up="$(advance_origin)"
	run --separate-stderr "$SCRIPT" run --branch second -- "task"
	[ "$status" -eq 0 ]
	[ "$(git -C "$REPO/.worktrees/second" rev-parse HEAD)" = "$up" ]
}

@test "changes in the Base branch's worktree abort with exit 3 even when it already has origin/main" {
	printf 'new\n' >untracked.txt
	assert_aborts --branch b -- "task"
	[[ "$stderr" == *"uncommitted or untracked"* ]] || false
}

@test "a non-main Base branch not checked out anywhere aborts with exit 3 even when no merge is needed" {
	git branch develop
	assert_aborts --base develop --branch b -- "task"
	[[ "$stderr" == *"not checked out"* ]] || false
}

@test "help run documents --no-base-update and exit 3" {
	run --separate-stderr "$SCRIPT" help run
	[ "$status" -eq 0 ]
	[[ "$output" == *"--no-base-update"* ]] || false
	[[ "$output" == *"  3    the Base update"* ]] || false
}

@test "Ctrl-C during the Base update exits 130 and creates nothing" {
	cat >"$STUBS/git" <<'STUB'
#!/bin/bash
if [ "$1" = "fetch" ]; then
	kill -INT "$PPID"
	sleep 1
fi
exec /usr/bin/git "$@"
STUB
	chmod +x "$STUBS/git"
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 130 ]
	[ -z "$output" ]
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
}

@test "a taken name exits 5 before the Base update fetches" {
	cat >"$STUBS/git" <<STUB
#!/bin/bash
[ "\$1" = "fetch" ] && printf 'fetch\n' >>"$HC_LOG/git-fetch"
exec /usr/bin/git "\$@"
STUB
	chmod +x "$STUBS/git"
	git branch feat/x
	advance_origin >/dev/null
	run --separate-stderr "$SCRIPT" run --branch feat/x -- "task"
	[ "$status" -eq 5 ]
	[ ! -e "$HC_LOG/git-fetch" ]
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
}
