#!/usr/bin/env bats
# --harness, --model and --effort, with hc, claude and codex stubbed on PATH.

load test_helper

setup() {
	setup_sandbox
	printf '#!/bin/bash\nexit 0\n' >"$STUBS/codex"
	chmod +x "$STUBS/codex"
	WT="$REPO/.worktrees/b"
}

expected_text() {
	printf '%s\n\n%s\n%s\n%s' "task" \
		"Work only in this worktree ($WT, branch b). Do not start other agents." \
		'Report with hc send tparent "<result or blocker>" when done or stuck, not just to acknowledge.' \
		"Write long answers to a file and send its path."
}

# Prints the expected full hc argv, one element per line, for the given
# harness argv (everything after `--cwd <path>`, without the text).
expected_argv() {
	printf '%s\n' run --bg --name b --cwd "$WT" "$@"
	expected_text
	printf '\n'
}

@test "--harness codex launches codex --no-daemon -- <text>" {
	run --separate-stderr "$SCRIPT" run --harness codex --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(hc_argv)" = "$(expected_argv codex --no-daemon --)" ]
}

@test "--harness codex passes --model as -m and --effort as -c model_reasoning_effort" {
	run --separate-stderr "$SCRIPT" run --harness=codex --model gpt-5.5 --effort=high --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(hc_argv)" = "$(expected_argv codex --no-daemon -m gpt-5.5 -c model_reasoning_effort=high --)" ]
}

@test "claude is the default harness and gets nothing extra without --model/--effort" {
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(hc_argv)" = "$(expected_argv claude --)" ]
}

@test "--harness claude passes --model and --effort through unvalidated" {
	run --separate-stderr "$SCRIPT" run --harness claude --model=opus --effort "very high" --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(hc_argv)" = "$(expected_argv claude --model opus --effort "very high" --)" ]
}

@test "--effort alone is passed on its own" {
	run --separate-stderr "$SCRIPT" run --harness codex --effort low --branch b -- "task"
	[ "$status" -eq 0 ]
	[ "$(hc_argv)" = "$(expected_argv codex --no-daemon -c model_reasoning_effort=low --)" ]
}

@test "an unknown --harness exits 2" {
	run --separate-stderr "$SCRIPT" run --harness foo --branch b -- "task"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"foo"* ]] || false
	assert_nothing_created
}

@test "--harness, --model and --effort without a value exit 2" {
	for f in --harness --model --effort; do
		run --separate-stderr "$SCRIPT" run --branch b "$f" -- "task"
		[ "$status" -eq 2 ]
	done
	assert_nothing_created
}

@test "--harness codex without codex on PATH exits 4, even with claude present" {
	rm "$STUBS/codex"
	run --separate-stderr "$SCRIPT" run --harness codex --branch b -- "task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"codex not found"* ]] || false
	assert_nothing_created
}

@test "--harness codex does not need claude on PATH" {
	rm "$STUBS/claude"
	run --separate-stderr "$SCRIPT" run --harness codex --branch b -- "task"
	[ "$status" -eq 0 ]
}

@test "the Codex run ends with the Codex warning and not the Claude one" {
	run --separate-stderr "$SCRIPT" run --harness codex --branch b -- "task"
	[ "$status" -eq 0 ]
	expected="$(
		cat <<'W'
Codex may ask before each `hc send`. To allow it for good, run:
  mkdir -p ~/.codex/rules
  echo 'prefix_rule(pattern=["hc", "send"], decision="allow")' >> ~/.codex/rules/default.rules
If Codex shows a trust dialog, open it with:
  hc attach t9z
W
	)"
	[ "$(printf '%s\n' "$stderr" | tail -n 5)" = "$expected" ]
	[[ "$stderr" != *"Claude may ask"* ]] || false
	[[ "$stderr" != *"settings.json"* ]] || false
}

@test "the Claude run has the Claude warning and not the Codex one" {
	run --separate-stderr "$SCRIPT" run --branch b -- "task"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"Claude may ask before each"* ]] || false
	[[ "$stderr" != *"Codex"* ]] || false
	[[ "$stderr" != *"hc attach"* ]] || false
}

@test "help run documents --harness, --model, --effort and a codex example" {
	run --separate-stderr "$SCRIPT" help run
	[ "$status" -eq 0 ]
	for s in "--harness <claude|codex>" "--model <s>" "--effort <s>" "run --harness codex"; do
		[[ "$output" == *"$s"* ]] || false
	done
}
