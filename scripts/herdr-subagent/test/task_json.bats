#!/usr/bin/env bats
# The task from stdin and the JSON line on stdout, with hc stubbed.

load test_helper

setup() {
	setup_sandbox
	WT="$REPO/.worktrees/b"
}

# The file holding the last hc argv element: the task handed to the template.
hc_task_file() {
	printf '%s' "$HC_LOG/arg.$(cat "$HC_LOG/argc")"
}

@test "a multi-line task with quotes, \$ and backticks on stdin is passed byte-for-byte" {
	cat >"$SANDBOX/task.txt" <<'EOF'
Fix "the" parser's $HOME handling.
Run `make test` and \n keep 'it' green.
EOF
	run --separate-stderr "$SCRIPT" start --branch b <"$SANDBOX/task.txt"
	[ "$status" -eq 0 ]
	cmp "$(hc_task_file)" "$SANDBOX/task.txt"
}

@test "the stdin task keeps every trailing newline, and works without one" {
	printf 'ends with two\n\n' >"$SANDBOX/task.txt"
	run --separate-stderr "$SCRIPT" start --branch b <"$SANDBOX/task.txt"
	[ "$status" -eq 0 ]
	cmp "$(hc_task_file)" "$SANDBOX/task.txt"

	rm -rf "$WT" "${HC_LOG:?}"/*
	git worktree prune
	git branch -D -q b
	printf 'no newline' >"$SANDBOX/task.txt"
	run --separate-stderr "$SCRIPT" start --branch b <"$SANDBOX/task.txt"
	[ "$status" -eq 0 ]
	cmp "$(hc_task_file)" "$SANDBOX/task.txt"
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

@test "stdout is one JSON line with the template and task_sent, and no harness or model" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
	[ "$(printf '%s' "$output" | jq -c .)" = "$(jq -nc --arg wt "$WT" \
		'{terminal:"t9z",name:"b",branch:"b",base:"main",worktree:$wt,template:"implementer",task_sent:true,reason:null}')" ]
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

@test "the JSON escapes \" and \\ in the base and worktree path, and control chars in the template" {
	odd="$SANDBOX/re\"po\\x"
	git clone -q "$SANDBOX/origin.git" "$odd" 2>/dev/null
	cd "$odd"
	git push -q origin 'main:we"ird'
	tpl="$(printf 'a"b\\c\td\001e')"
	export HC_STUB_TEMPLATES
	HC_STUB_TEMPLATES="$(jq -nc --arg n "$tpl" '{templates:[{name:$n,description:"d",command:"c"}]}')"
	run --separate-stderr "$SCRIPT" start --template "$tpl" \
		--base 'we"ird' --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -c .)" = "$(jq -nc --arg wt "$odd/.worktrees/b" --arg t "$tpl" \
		'{terminal:"t9z",name:"b",branch:"b",base:"we\"ird",worktree:$wt,template:$t,task_sent:true,reason:null}')" ]
}
