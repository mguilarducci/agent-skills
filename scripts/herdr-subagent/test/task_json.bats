#!/usr/bin/env bats
# --task-file and --json, with hc and claude stubbed on PATH.

load test_helper

setup() {
	setup_sandbox
	WT="$REPO/.worktrees/b"
}

# The report-back text the script appends after the task.
report_text() {
	printf '%s\n%s\n%s' \
		"Work only in this worktree ($WT, branch b). Do not start other agents." \
		'Report with hc send tparent "<result or blocker>" when done or stuck, not just to acknowledge.' \
		"Write long answers to a file and send its path."
}

# The last hc argv element: the text handed to the harness.
hc_text() {
	hc_arg "$(cat "$HC_LOG/argc")"
}

@test "--task-file - passes a multi-line task with quotes, \$ and backticks byte-for-byte" {
	run --separate-stderr "$SCRIPT" run --branch b --task-file - <<'EOF'
Fix "the" parser's $HOME handling.
Run `make test` and \n keep 'it' green.
EOF
	[ "$status" -eq 0 ]
	[ "$output" = "t9z" ]
	expected="$(printf '%s\n%s\n\n%s' \
		"Fix \"the\" parser's \$HOME handling." \
		"Run \`make test\` and \\n keep 'it' green." \
		"$(report_text)")"
	[ "$(hc_text)" = "$expected" ]
}

@test "--task-file <path> reads the task from that file" {
	printf 'from a file\n' >"$SANDBOX/task.txt"
	run --separate-stderr "$SCRIPT" run --task-file="$SANDBOX/task.txt" --branch b
	[ "$status" -eq 0 ]
	[ "$(hc_text)" = "$(printf 'from a file\n\n%s' "$(report_text)")" ]
}

@test "--task-file together with a task after -- exits 2" {
	printf 'x\n' >"$SANDBOX/task.txt"
	run --separate-stderr "$SCRIPT" run --branch b --task-file "$SANDBOX/task.txt" -- "task"
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ "$stderr" == *"not both"* ]] || false
	assert_nothing_created
}

@test "a missing, unreadable or empty --task-file exits 2" {
	: >"$SANDBOX/empty.txt"
	printf '\n\n' >"$SANDBOX/newlines.txt"
	mkdir "$SANDBOX/dir"
	printf 'x\n' >"$SANDBOX/locked.txt"
	chmod 000 "$SANDBOX/locked.txt"
	for f in "$SANDBOX/nope.txt" "$SANDBOX/empty.txt" "$SANDBOX/newlines.txt" "$SANDBOX/dir" "$SANDBOX/locked.txt"; do
		run --separate-stderr "$SCRIPT" run --branch b --task-file "$f"
		[ "$status" -eq 2 ]
		[ -z "$output" ]
		[[ "$stderr" == *"$f"* ]] || false
	done
	run --separate-stderr "$SCRIPT" run --branch b --task-file - </dev/null
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "--task-file without a value exits 2" {
	run --separate-stderr "$SCRIPT" run --branch b --task-file
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "--json prints one JSON object on stdout with model null when --model is left out" {
	run --separate-stderr "$SCRIPT" run --json --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
	[ "$(printf '%s' "$output" | jq -c .)" = "$(jq -nc --arg wt "$WT" \
		'{terminal:"t9z",name:"b",branch:"b",base:"main",worktree:$wt,harness:"claude",model:null}')" ]
	[[ "$stderr" == *"started Herdr subagent t9z"* ]] || false
}

@test "help run documents --task-file with a heredoc example, and --json" {
	run --separate-stderr "$SCRIPT" help run
	[ "$status" -eq 0 ]
	[[ "$output" == *"--task-file - <<'EOF'"* ]] || false
	[[ "$output" == *"--task-file <path|->"* ]] || false
	[[ "$output" == *"--json"* ]] || false
}

@test "--json escapes \" and \\ in the base and worktree path, and control chars in the model" {
	odd="$SANDBOX/re\"po\\x"
	git clone -q "$SANDBOX/origin.git" "$odd" 2>/dev/null
	cd "$odd"
	git branch 'we"ird' main
	model="$(printf 'a"b\\c\td\001e')"
	run --separate-stderr "$SCRIPT" run --json --harness claude --model "$model" \
		--base 'we"ird' --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -c .)" = "$(jq -nc --arg wt "$odd/.worktrees/b" --arg m "$model" \
		'{terminal:"t9z",name:"b",branch:"b",base:"we\"ird",worktree:$wt,harness:"claude",model:$m}')" ]
}
