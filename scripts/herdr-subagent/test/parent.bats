#!/usr/bin/env bats
# The parent a Herdr subagent reports to, with hc stubbed.
# The messages quote shell commands in backticks on purpose.
# shellcheck disable=SC2016

load test_helper

setup() {
	setup_sandbox
}

@test "the parent defaults to \$HC_TERMINAL_ID and is passed to hc run" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_flag_values --parent)" = "tparent" ]
}

@test "--parent wins over \$HC_TERMINAL_ID and works without it" {
	run --separate-stderr "$SCRIPT" start --branch b --parent t7 <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_flag_values --parent)" = "t7" ]

	unset HC_TERMINAL_ID
	run --separate-stderr "$SCRIPT" start --branch c --parent=orchestrator <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_flag_values --parent)" = "orchestrator" ]
}

@test "no parent exits 4 with nothing created and says how to get one" {
	unset HC_TERMINAL_ID
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *'run it from an hc terminal, under `hc run --bg`, or pass `--parent <t>`'* ]] || false
	assert_nothing_created

	HC_TERMINAL_ID="" run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	assert_nothing_created
}

@test "a parent hc does not know exits 4 with nothing created" {
	HC_STUB_GET='{"error":{"kind":"not_found","message":"no terminal \"t7\""}}' HC_STUB_GET_EXIT=3 \
		run --separate-stderr "$SCRIPT" start --branch b --parent t7 <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"t7"* ]] || false
	[[ "$stderr" == *'or pass `--parent <t>`'* ]] || false
	assert_nothing_created
}

@test "a finished parent exits 4 with nothing created" {
	HC_STUB_GET='{"address":"t7","state":"finished","parent":null}' \
		run --separate-stderr "$SCRIPT" start --branch b --parent t7 <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"t7 is not a live hc terminal"* ]] || false
	assert_nothing_created
}

@test "the parent is checked as live through hc get" {
	run --separate-stderr "$SCRIPT" start --branch b --parent t7 <<<"task"
	[ "$status" -eq 0 ]
	[ "$(cat "$HC_LOG/get-calls")" = "get t7 --json" ]
}

@test "the parent is not copied into labels" {
	run --separate-stderr "$SCRIPT" start --branch b --parent t7 <<<"task"
	[ "$status" -eq 0 ]
	if hc_flag_values --label | grep -q t7; then false; fi
	[ "$(printf '%s' "$output" | jq -r '.labels | to_entries[] | .value' | grep -c t7)" -eq 0 ]
}
