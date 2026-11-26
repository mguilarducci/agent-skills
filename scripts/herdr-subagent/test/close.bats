#!/usr/bin/env bats
# `close <branch>` kills the Herdr subagent's terminal, removes its worktree
# and deletes its branch only once merged into origin/<base>.
# Real git with a local bare origin; the hc stub answers ls, get, kill, rm.

load test_helper

setup() {
	setup_sandbox
}

# A Herdr subagent's worktree as start leaves it: .worktrees/<slug> on a new
# branch $1 from origin/main, with one commit.
make_worktree() {
	local branch="$1" slug="${2:-$1}"
	git worktree add -q --no-track -b "$branch" "$REPO/.worktrees/$slug" refs/remotes/origin/main
	printf '%s\n' "$branch" >"$REPO/.worktrees/$slug/work.txt"
	git -C "$REPO/.worktrees/$slug" add -A
	git -C "$REPO/.worktrees/$slug" commit -q -m "work on $branch"
}

# Merge branch $1 into origin/$2 (default main) with a merge commit, as a PR.
merge_on_origin() {
	local branch="$1" base="${2:-main}" other="$SANDBOX/other"
	git push -q origin "$branch"
	[ -d "$other" ] || git clone -q "$SANDBOX/origin.git" "$other" 2>/dev/null
	git -C "$other" fetch -q origin
	git -C "$other" checkout -q -B "$base" "origin/$base"
	git -C "$other" merge -q --no-ff -m "Merge $branch" "origin/$branch"
	git -C "$other" push -q origin "$base"
}

# Make hc know one labelled terminal t5 (state $1, default live) whose
# subagent.base is $2 (default main; "-" for none).
with_terminal() {
	local state="${1:-live}" base="${2:-main}" labels
	export HC_STUB_LS='{"hidden_finished":0,"terminals":[{"address":"t5","agent":"claude-code","name":"b","state":"'"$state"'","turn":3}]}'
	labels='"subagent.repo":"'"$REPO"'","subagent.branch":"b"'
	[ "$base" = "-" ] || labels="$labels"',"subagent.base":"'"$base"'"'
	export HC_STUB_GET='{"address":"t5","state":"'"$state"'","labels":{'"$labels"'}}'
}

no_terminal() {
	export HC_STUB_LS='{"hidden_finished":0,"terminals":[]}'
}

has_branch() {
	git show-ref --verify --quiet "refs/heads/$1"
}

@test "a merged branch: the terminal is killed and removed, the worktree and branch are gone" {
	make_worktree b
	merge_on_origin b
	with_terminal live
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":true,"worktree_removed":true,"branch_deleted":true,"branch_kept_reason":null}' ]
	[ "$(cat "$HC_LOG/kill-calls")" = "kill t5 --json" ]
	[ "$(cat "$HC_LOG/rm-calls")" = "rm t5 --json" ]
	grep -qxF -- "ls --all --json --label subagent.repo=$REPO --label subagent.branch=b" "$HC_LOG/ls-calls"
	[ ! -e "$REPO/.worktrees/b" ]
	run ! has_branch b
}

@test "an unmerged, pushed branch is kept and the JSON says why" {
	make_worktree b
	git push -q origin b
	with_terminal live
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":true,"worktree_removed":true,"branch_deleted":false,"branch_kept_reason":"not merged into origin/main; pushed to origin/b"}' ]
	[ ! -e "$REPO/.worktrees/b" ]
	has_branch b
}

@test "an unmerged, unpushed branch is kept and the JSON says why" {
	make_worktree b
	git push -q origin b
	git -C "$REPO/.worktrees/b" commit -q --allow-empty -m "local only"
	with_terminal live
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":true,"worktree_removed":true,"branch_deleted":false,"branch_kept_reason":"not merged into origin/main; not pushed (its tip is not on origin)"}' ]
	[ ! -e "$REPO/.worktrees/b" ]
	has_branch b
}

@test "a failed fetch keeps the branch with the reason, and still cleans up the terminal and worktree" {
	make_worktree b
	merge_on_origin b
	git fetch -q origin
	with_terminal live
	git remote set-url origin "$SANDBOX/gone.git"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":true,"worktree_removed":true,"branch_deleted":false,"branch_kept_reason":"could not check the merge: git fetch origin main failed"}' ]
	[ "$(cat "$HC_LOG/rm-calls")" = "rm t5 --json" ]
	[ ! -e "$REPO/.worktrees/b" ]
	has_branch b
}

@test "no origin keeps the branch with the reason" {
	make_worktree b
	no_terminal
	git remote remove origin
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":false,"worktree_removed":true,"branch_deleted":false,"branch_kept_reason":"could not check the merge: no origin remote"}' ]
	has_branch b
}

@test "the base comes from the terminal's subagent.base label" {
	git push -q origin main:develop
	make_worktree b
	merge_on_origin b develop
	with_terminal finished develop
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":true,"worktree_removed":true,"branch_deleted":true,"branch_kept_reason":null}' ]
	[ "$(cat "$HC_LOG/get-calls")" = "get t5 --json" ]
}

@test "a branch merged into another base is kept when the base label says main" {
	git push -q origin main:develop
	make_worktree b
	merge_on_origin b develop
	with_terminal live main
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":true,"worktree_removed":true,"branch_deleted":false,"branch_kept_reason":"not merged into origin/main; pushed to origin/b"}' ]
}

@test "without a terminal record the base falls back to main" {
	git push -q origin main:develop
	make_worktree b
	merge_on_origin b develop
	no_terminal
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":"'"$REPO"'/.worktrees/b","terminal_killed":false,"worktree_removed":true,"branch_deleted":false,"branch_kept_reason":"not merged into origin/main; pushed to origin/b"}' ]
	[ ! -e "$HC_LOG/kill-calls" ]
	[ ! -e "$HC_LOG/rm-calls" ]

	make_worktree c
	merge_on_origin c
	run --separate-stderr "$SCRIPT" close c
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"c","worktree":"'"$REPO"'/.worktrees/c","terminal_killed":false,"worktree_removed":true,"branch_deleted":true,"branch_kept_reason":null}' ]
}

@test "uncommitted or untracked changes exit 3 and touch nothing" {
	make_worktree b
	merge_on_origin b
	with_terminal live
	printf 'more\n' >>"$REPO/.worktrees/b/work.txt"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 3 ]
	[ -z "$output" ]
	[ ! -e "$HC_LOG/kill-calls" ]
	[ ! -e "$HC_LOG/rm-calls" ]
	[ -f "$REPO/.worktrees/b/work.txt" ]
	has_branch b

	git -C "$REPO/.worktrees/b" checkout -q -- work.txt
	printf 'new\n' >"$REPO/.worktrees/b/new.txt"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 3 ]
	[ -z "$output" ]
	[ ! -e "$HC_LOG/kill-calls" ]
	[ -f "$REPO/.worktrees/b/new.txt" ]
	has_branch b
}

@test "a branch with neither a worktree nor a labelled terminal exits 5" {
	no_terminal
	run --separate-stderr "$SCRIPT" close nope
	[ "$status" -eq 5 ]
	[ -z "$output" ]
	[ ! -e "$HC_LOG/kill-calls" ]
}

@test "a terminal without its worktree is still killed and removed" {
	make_worktree b
	git worktree remove "$REPO/.worktrees/b"
	merge_on_origin b
	with_terminal finished
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":null,"terminal_killed":true,"worktree_removed":false,"branch_deleted":true,"branch_kept_reason":null}' ]
	[ "$(cat "$HC_LOG/rm-calls")" = "rm t5 --json" ]
}

@test "rerunning close after a partial failure finishes the cleanup" {
	make_worktree b
	merge_on_origin b
	with_terminal live
	export HC_STUB_KILL_EXIT=1
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ -d "$REPO/.worktrees/b" ]
	has_branch b

	# hc rm is the last step: everything else is done when it fails.
	export HC_STUB_KILL_EXIT=0 HC_STUB_RM_EXIT=1
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ ! -e "$REPO/.worktrees/b" ]
	run ! has_branch b

	export HC_STUB_RM_EXIT=0
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":null,"terminal_killed":true,"worktree_removed":false,"branch_deleted":false,"branch_kept_reason":"no local branch b"}' ]

	# The terminal record is gone now; a third close finds nothing.
	no_terminal
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 5 ]
}

@test "a failed branch delete: the hc record is kept, and a rerun finishes even with only the branch left" {
	make_worktree b
	merge_on_origin b
	with_terminal live
	# A held ref lock makes `git branch -D` fail.
	: >"$REPO/.git/refs/heads/b.lock"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ "$(cat "$HC_LOG/kill-calls")" = "kill t5 --json" ]
	# hc rm comes last, so the terminal record (and its base label) survives.
	[ ! -e "$HC_LOG/rm-calls" ]
	[ ! -e "$REPO/.worktrees/b" ]
	has_branch b

	rm "$REPO/.git/refs/heads/b.lock"
	no_terminal
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":null,"terminal_killed":false,"worktree_removed":false,"branch_deleted":true,"branch_kept_reason":null}' ]
	run ! has_branch b
}

@test "a rerun after a failed branch delete still uses the base label" {
	git push -q origin main:develop
	make_worktree b
	merge_on_origin b develop
	with_terminal live develop
	: >"$REPO/.git/refs/heads/b.lock"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 1 ]
	[ ! -e "$HC_LOG/rm-calls" ]

	rm "$REPO/.git/refs/heads/b.lock"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$output" = '{"branch":"b","worktree":null,"terminal_killed":true,"worktree_removed":false,"branch_deleted":true,"branch_kept_reason":null}' ]
	[ "$(cat "$HC_LOG/rm-calls")" = "rm t5 --json" ]
}

@test "close works from a linked worktree too" {
	make_worktree b
	merge_on_origin b
	git worktree add -q -b other "$SANDBOX/elsewhere"
	with_terminal live
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	grep -qxF -- "ls --all --json --label subagent.repo=$REPO --label subagent.branch=b" "$HC_LOG/ls-calls"
	run ! has_branch b
}

@test "close takes exactly one valid branch, and has no --force" {
	make_worktree b
	with_terminal live
	for args in "" "b c" "--force b" "b --force" "-f b" "bad..name"; do
		# shellcheck disable=SC2086 # split on purpose
		run --separate-stderr "$SCRIPT" close $args
		[ "$status" -eq 2 ]
		[ -z "$output" ]
	done
	[ ! -e "$HC_LOG/ls-calls" ]
	[ -d "$REPO/.worktrees/b" ]
}

@test "the branch checked out in the main checkout is refused" {
	no_terminal
	run --separate-stderr "$SCRIPT" close main
	[ "$status" -eq 2 ]
	has_branch main
}

@test "a worktree for the branch outside .worktrees/<slug> is refused and nothing is touched" {
	git worktree add -q --no-track -b feat/b "$SANDBOX/elsewhere" refs/remotes/origin/main
	with_terminal live
	run --separate-stderr "$SCRIPT" close feat/b
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ "$stderr" == *"$SANDBOX/elsewhere"* ]] || false
	[[ "$stderr" == *"$REPO/.worktrees/feat-b"* ]] || false
	[ ! -e "$HC_LOG/kill-calls" ]
	[ -d "$SANDBOX/elsewhere" ]
	has_branch feat/b
}

@test "close without hc or outside a git repo exits 4 and touches nothing" {
	make_worktree b
	rm "$STUBS/hc"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 4 ]
	cd "$SANDBOX"
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 4 ]
	[ -d "$REPO/.worktrees/b" ]
}

@test "a failing hc ls exits 4 and touches nothing" {
	make_worktree b
	export HC_STUB_LS_EXIT=1
	run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 4 ]
	[ -d "$REPO/.worktrees/b" ]
	has_branch b
}
