#!/usr/bin/env bats
# Usage errors (exit 2) and missing prerequisites (exit 4) create nothing.

load test_helper

setup() {
	setup_sandbox
}

@test "missing --branch exits 2" {
	run --separate-stderr "$SCRIPT" start <<<"task"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"--branch"* ]] || false
	assert_nothing_created
}

@test "a branch name git rejects exits 2" {
	for b in "feat..x" "feat/" "-x" "a.lock" "feat/.x"; do
		run --separate-stderr "$SCRIPT" start --branch "$b" <<<"task"
		[ "$status" -eq 2 ]
	done
	assert_nothing_created
}

@test "a branch name outside ASCII [A-Za-z0-9._/-] exits 2" {
	for b in "feat/olá" "feat x" "feat@x" "feat+x"; do
		run --separate-stderr "$SCRIPT" start --branch "$b" <<<"task"
		[ "$status" -eq 2 ]
	done
	assert_nothing_created
}

@test "outside a git repo exits 4" {
	mkdir "$SANDBOX/plain"
	cd "$SANDBOX/plain"
	GIT_CEILING_DIRECTORIES="$SANDBOX" run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	[ -z "$output" ]
	assert_nothing_created
}

@test "no hc on PATH exits 4" {
	rm "$STUBS/hc"
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"hc"* ]] || false
	assert_nothing_created
}
