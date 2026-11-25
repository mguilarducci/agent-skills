#!/usr/bin/env bats
# --dry-run, with hc and claude stubbed on PATH.

load test_helper

setup() {
	setup_sandbox
	WT="$REPO/.worktrees/b"
	# Records every git fetch, then runs the real git.
	cat >"$STUBS/git" <<'STUB'
#!/bin/bash
for a in "$@"; do
	[ "$a" = "fetch" ] && printf '%s\n' "$*" >>"$HC_LOG/fetch-calls"
done
exec /usr/bin/git "$@"
STUB
	chmod +x "$STUBS/git"
}

# Pushes one commit to origin/main from another clone, so a Base update has
# something to bring in.
advance_origin_main() {
	git clone -q "$SANDBOX/origin.git" "$SANDBOX/other" 2>/dev/null
	git -C "$SANDBOX/other" commit -q --allow-empty -m upstream
	git -C "$SANDBOX/other" push -q origin main
}

# Runs each line of $1 in a fresh bash from $REPO, stopping at the first failure.
paste_lines() {
	local line
	while IFS= read -r line; do
		(cd "$REPO" && /bin/bash -c "$line") || return 1
	done <<EOF
$1
EOF
}

# Removes what a run created, so the next run starts from the same names.
undo_run() {
	git -C "$REPO" worktree remove --force "$WT"
	git -C "$REPO" branch -q -D b
	rm -f "$HC_LOG"/arg.* "$HC_LOG/argc"
}

@test "--dry-run creates no branch, worktree or terminal, doesn't fetch, and exits 0" {
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	assert_nothing_created
	[ ! -e "$HC_LOG/fetch-calls" ]
}

@test "each printed line, pasted into a shell, runs the same commands as the real run" {
	advance_origin_main
	task="$(printf '%s\n%s' "Fix \"the\" parser's \$HOME and \`ls\`." "Line two; \\n stays")"
	run --separate-stderr "$SCRIPT" run --dry-run --model 'my model' --effort high --branch b -- "$task"
	[ "$status" -eq 0 ]
	plan="$output"
	[ "$(printf '%s\n' "$plan" | wc -l | tr -d ' ')" = "4" ]
	assert_nothing_created

	paste_lines "$plan"
	[ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ]
	[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "b" ]
	pasted="$(hc_argv)"
	undo_run

	run --separate-stderr "$SCRIPT" run --model 'my model' --effort high --branch b -- "$task"
	[ "$status" -eq 0 ]
	[ "$(hc_argv)" = "$pasted" ]
}

@test "a --model with a newline but otherwise safe characters stays on one line" {
	run --separate-stderr "$SCRIPT" run --dry-run --no-base-update --model "$(printf 'a\nb')" --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
	paste_lines "$output"
	[ "$(hc_arg 9)" = "$(printf 'a\nb')" ]
}

@test "--dry-run still exits 2 on bad arguments, 4 on missing prerequisites and 5 on taken names" {
	run --separate-stderr "$SCRIPT" run --dry-run -- "task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" run -n --base nope --branch b -- "task"
	[ "$status" -eq 2 ]

	HC_TERMINAL_ID="" run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 4 ]
	rm "$STUBS/claude"
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 4 ]
	printf '#!/bin/bash\nexit 0\n' >"$STUBS/claude"
	chmod +x "$STUBS/claude"

	HC_STUB_LS='{"terminals":[{"address":"t1","name":"b"}]}' \
		run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 5 ]
	[ -z "$output" ]
	git -C "$REPO" branch b
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 5 ]
	[ -z "$output" ]
	[ ! -e "$HC_LOG/argc" ]
	[ ! -e "$HC_LOG/fetch-calls" ]
}

@test "--no-base-update drops the Base update lines from the plan" {
	run --separate-stderr "$SCRIPT" run --dry-run --no-base-update --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "2" ]
	[[ "${lines[0]}" == "git worktree add -b b $WT refs/heads/main" ]] || false
	[[ "${lines[1]}" == "hc run --bg --name b --cwd $WT claude -- "* ]] || false
}

@test "a main checked out nowhere is planned as a ref update, which works when pasted" {
	advance_origin_main
	git -C "$REPO" checkout -q --detach
	old="$(git -C "$REPO" rev-parse main)"
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "git fetch -q origin" ]
	[ "${lines[1]}" = "git merge-base --is-ancestor refs/heads/main refs/remotes/origin/main && git update-ref -m 'herdr-subagent: Base update' refs/heads/main refs/remotes/origin/main $old" ]
	paste_lines "$(printf '%s\n' "${lines[0]}" "${lines[1]}")"
	[ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ]
}

@test "the pasted ref update never moves a main checked out nowhere backward" {
	ahead() {
		run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
		[ "$status" -eq 0 ]
		(cd "$REPO" && /bin/bash -c "${lines[0]}" && /bin/bash -c "${lines[1]}") || true
		[ "$(git -C "$REPO" rev-parse main)" = "$1" ]
	}
	# main ahead of origin/main
	git -C "$REPO" commit -q --allow-empty -m local
	git -C "$REPO" checkout -q --detach
	ahead "$(git -C "$REPO" rev-parse main)"
	# main diverged from origin/main
	advance_origin_main
	ahead "$(git -C "$REPO" rev-parse main)"
}

@test "another Base is planned as a merge in the worktree that has it checked out" {
	git -C "$REPO" checkout -q -b develop
	run --separate-stderr "$SCRIPT" run --dry-run --base develop --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "git fetch -q origin" ]
	[ "${lines[1]}" = "git -C $REPO merge -q --no-edit --no-squash --commit origin/main" ]
	[ "${lines[2]}" = "git worktree add -b b $WT refs/heads/develop" ]
}

@test "a Base update run would abort on, and that is known without fetching, is noted on stderr" {
	git -C "$REPO" branch develop
	run --separate-stderr "$SCRIPT" run --dry-run --base develop --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "git fetch -q origin" ]
	[ "${lines[1]}" = "git worktree add -b b $WT refs/heads/develop" ]
	[[ "$stderr" == *"develop is not checked out in any worktree"*"exit 3"* ]] || false
	[[ "$stderr" != *"unless"* ]] || false

	git -C "$REPO" remote remove origin
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"no origin remote"*"exit 3"* ]] || false
}

@test "changes in the Base branch's worktree are noted on stderr as an exit-3 abort" {
	printf 'new\n' >"$REPO/untracked.txt"
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"uncommitted or untracked"*"exit 3"* ]] || false
}

@test "--dry-run --json prints the --json object with terminal null and the commands" {
	run --separate-stderr "$SCRIPT" run --dry-run --json --branch b -- "$(printf 'two\nlines')"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
	[ "$(printf '%s' "$output" | jq -r '.terminal')" = "null" ]
	[ "$(printf '%s' "$output" | jq -r '.name, .branch, .base, .harness')" = "$(printf 'b\nb\nmain\nclaude')" ]
	[ "$(printf '%s' "$output" | jq -r '.worktree')" = "$WT" ]
	[ "$(printf '%s' "$output" | jq -r '.commands | length')" = "4" ]
	[ "$(printf '%s' "$output" | jq -r '.commands[2]')" = "git worktree add -b b $WT refs/heads/main" ]

	json="$output"
	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "$(printf 'two\nlines')"
	[ "$(printf '%s' "$json" | jq -r '.commands[]')" = "$output" ]
	assert_nothing_created
}

@test "stderr has the summary and the harness warning, with a placeholder for the terminal id" {
	printf '#!/bin/bash\nexit 0\n' >"$STUBS/codex"
	chmod +x "$STUBS/codex"
	run --separate-stderr "$SCRIPT" run --dry-run --harness codex --branch b -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"dry run"*"<terminal> (b)"* ]] || false
	[[ "$stderr" == *"worktree: $WT"* ]] || false
	[[ "$stderr" == *"hc wait <terminal>"* ]] || false
	[[ "$stderr" == *"Codex may ask"*"hc attach <terminal>"* ]] || false
	[[ "$output" != *"<terminal>"* ]] || false

	run --separate-stderr "$SCRIPT" run --dry-run --branch b -- "task"
	[[ "$stderr" == *"Claude may ask"* ]] || false
}

@test "help run documents -n/--dry-run with a --dry-run --json example" {
	run --separate-stderr "$SCRIPT" help run
	[ "$status" -eq 0 ]
	[[ "$output" == *"-n, --dry-run"* ]] || false
	[[ "$output" == *"run --dry-run --json "* ]] || false
}
