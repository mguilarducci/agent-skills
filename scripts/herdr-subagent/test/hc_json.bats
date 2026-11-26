#!/usr/bin/env bats
# hc's JSON is read by key path: a nested object with the same key never
# stands in for the field the script wants.

load test_helper

setup() {
	setup_sandbox
}

@test "a nested name in hc ls is not a live name conflict" {
	HC_STUB_LS='{"terminals":[{"address":"t1","name":"other","labels":{"name":"b"}}]}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
}

@test "a nested state does not make a finished parent live" {
	HC_STUB_GET='{"address":"t7","state":"finished","last":{"state":"live"}}' \
		run --separate-stderr "$SCRIPT" start --branch b --parent t7 <<<"task"
	[ "$status" -eq 4 ]
	assert_nothing_created
}

@test "a nested name in hc templates is not a listed template" {
	HC_STUB_TEMPLATES='{"templates":[{"name":"other","vars":{"name":"implementer"}}]}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	assert_nothing_created
}

@test "the terminal is hc run's own address, not a nested one" {
	HC_STUB_OUTPUT='{"address":"t9z","parent":{"address":"tparent"},"first_message":{"sent":true,"reason":null}}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[[ "$output" == '{"terminal":"t9z",'* ]] || false
}

@test "first_message.sent is read from first_message itself, not a nested object" {
	HC_STUB_OUTPUT='{"address":"t9z","first_message":{"detail":{"sent":true},"sent":false,"reason":"busy"}}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 6 ]
	[[ "$output" == *'"task_sent":false,"reason":"busy"}' ]] || false
}

@test "hc's reason is unescaped once on stderr: \\n, \\\\ and \\\"" {
	HC_STUB_OUTPUT='{"address":"t9z","first_message":{"sent":false,"reason":"line \"one\"\nC:\\dir\\\\n"}}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 6 ]
	[[ "$output" == *'"reason":"line \"one\"\nC:\\dir\\\\n"}' ]] || false
	[[ "$stderr" == *'line "one"'$'\n''C:\dir\\n; the terminal'* ]] || false
}

@test "\\u escapes in hc's reason decode to UTF-8, surrogate pairs too" {
	# $u is a backslash and "u", so the JSON holds real backslash-u escapes.
	local u
	u="$(printf '\134u')"
	HC_STUB_OUTPUT='{"address":"t9z","first_message":{"sent":false,"reason":"caf'"$u"'00e9 '"$u"'d83d'"$u"'de00 '"$u"'0041\/"}}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 6 ]
	[[ "$stderr" == *"café 😀 A/; the terminal"* ]] || false
}

@test "close kills only the listed terminals, not nested addresses" {
	git worktree add -q --no-track -b b "$REPO/.worktrees/b" refs/remotes/origin/main
	HC_STUB_LS='{"terminals":[{"address":"t5","parent":{"address":"tparent"}}]}' \
		HC_STUB_GET='{"address":"t5","state":"live","labels":{"subagent.base":"main"}}' \
		run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[ "$(cat "$HC_LOG/kill-calls")" = "kill t5 --json" ]
}

@test "close reads subagent.base from the terminal's labels, not a nested object" {
	git push -q origin main:develop
	git worktree add -q --no-track -b b "$REPO/.worktrees/b" refs/remotes/origin/develop
	git -C "$REPO/.worktrees/b" commit -q --allow-empty -m work
	git push -q origin b:develop
	HC_STUB_LS='{"terminals":[{"address":"t5"}]}' \
		HC_STUB_GET='{"address":"t5","labels":{"subagent.base":"develop"},"meta":{"subagent.base":"main"}}' \
		run --separate-stderr "$SCRIPT" close b
	[ "$status" -eq 0 ]
	[[ "$output" == *'"branch_deleted":true,'* ]] || false
}
