#!/usr/bin/env bats
# The task from stdin and the JSON line on stdout, with hc and claude stubbed.

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

@test "a multi-line task with quotes, \$ and backticks on stdin is passed byte-for-byte" {
	run --separate-stderr "$SCRIPT" start --branch b <<'EOF'
Fix "the" parser's $HOME handling.
Run `make test` and \n keep 'it' green.
EOF
	[ "$status" -eq 0 ]
	expected="$(printf '%s\n%s\n\n\n%s' \
		"Fix \"the\" parser's \$HOME handling." \
		"Run \`make test\` and \\n keep 'it' green." \
		"$(report_text)")"
	[ "$(hc_text)" = "$expected" ]
}

@test "the stdin task keeps every trailing newline, and works without one" {
	printf 'ends with two\n\n' >"$SANDBOX/task.txt"
	run --separate-stderr "$SCRIPT" start --branch b <"$SANDBOX/task.txt"
	[ "$status" -eq 0 ]
	[ "$(hc_text)" = "$(printf 'ends with two\n\n\n\n%s' "$(report_text)")" ]

	rm -rf "$WT" "${HC_LOG:?}"/*
	git worktree prune
	git branch -D -q b
	printf 'no newline' >"$SANDBOX/task.txt"
	run --separate-stderr "$SCRIPT" start --branch b <"$SANDBOX/task.txt"
	[ "$status" -eq 0 ]
	[ "$(hc_text)" = "$(printf 'no newline\n\n%s' "$(report_text)")" ]
}

@test "an empty or whitespace-only stdin exits 2 and creates nothing" {
	: >"$SANDBOX/empty.txt"
	printf '\n\n' >"$SANDBOX/newlines.txt"
	printf ' \t\n \n' >"$SANDBOX/blank.txt"
	for f in /dev/null "$SANDBOX/empty.txt" "$SANDBOX/newlines.txt" "$SANDBOX/blank.txt"; do
		run --separate-stderr "$SCRIPT" start --branch b <"$f"
		[ "$status" -eq 2 ]
		[ -z "$output" ]
		[[ "$stderr" == *"empty task on stdin"* ]] || false
	done
	assert_nothing_created
}

@test "stdin attached to a TTY exits 2 and creates nothing" {
	# script(1) gives the command a pseudo-terminal as stdin.
	run script -q /dev/null "$SCRIPT" start --branch b </dev/null
	[ "$status" -eq 2 ]
	[[ "$output" == *"stdin is a terminal"* ]] || false
	assert_nothing_created
}

@test "stdout is one JSON line with model null when --model is left out" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
	[ "$(printf '%s' "$output" | jq -c .)" = "$(jq -nc --arg wt "$WT" \
		'{terminal:"t9z",name:"b",branch:"b",base:"main",worktree:$wt,harness:"claude",model:null}')" ]
}

@test "stderr has progress and one started line, and no summary or hints" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$stderr" | grep -c '^herdr-subagent: started ')" = "1" ]
	[[ "$stderr" == *"herdr-subagent: started Herdr subagent t9z (b)"* ]] || false
	for s in "Next:" "hc read" "hc send" "hc wait" "hc kill" "hc attach" \
		"may ask" "settings.json" "not ignored" "worktree:" "branch:"; do
		[[ "$stderr" != *"$s"* ]] || false
	done
	# Only "herdr-subagent: ..." lines: no blank lines or indented blocks.
	[ "$(printf '%s\n' "$stderr" | grep -vc '^herdr-subagent: ')" = 0 ]
}

@test "the JSON escapes \" and \\ in the base and worktree path, and control chars in the model" {
	odd="$SANDBOX/re\"po\\x"
	git clone -q "$SANDBOX/origin.git" "$odd" 2>/dev/null
	cd "$odd"
	git branch 'we"ird' main
	model="$(printf 'a"b\\c\td\001e')"
	run --separate-stderr "$SCRIPT" start --harness claude --model "$model" \
		--no-base-update --base 'we"ird' --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -c .)" = "$(jq -nc --arg wt "$odd/.worktrees/b" --arg m "$model" \
		'{terminal:"t9z",name:"b",branch:"b",base:"we\"ird",worktree:$wt,harness:"claude",model:$m}')" ]
}
