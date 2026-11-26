#!/usr/bin/env bats
# --template: start launches the Herdr subagent from an hc template.

load test_helper

setup() {
	setup_sandbox
	WT="$REPO/.worktrees/b"
}

@test "implementer is the default template, and the task is its only argument" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_template)" = "implementer" ]
	[ "$(hc_argv | sed -n '/^--$/,$p')" = "$(printf '%s\n' -- implementer task '')" ]
}

@test "--template picks the hc template, in either flag form" {
	run --separate-stderr "$SCRIPT" start --template implementer-codex --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_template)" = "implementer-codex" ]
	[ "$(printf '%s' "$output" | jq -r .template)" = "implementer-codex" ]

	rm -rf "$WT" "${HC_LOG:?}"/*
	git worktree prune
	git branch -D -q b
	run --separate-stderr "$SCRIPT" start --branch b --template=implementer-codex <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_template)" = "implementer-codex" ]
}

@test "a template hc templates doesn't list exits 4, says where templates go, and creates nothing" {
	run --separate-stderr "$SCRIPT" start --template reviewer --branch b <<<"task"
	[ "$status" -eq 4 ]
	[ -z "$output" ]
	[[ "$stderr" == *"template not found: reviewer"* ]] || false
	[[ "$stderr" == *"~/.config/herdr-core/templates/reviewer.md"* ]] || false
	[[ "$stderr" == *"scripts/herdr-subagent/templates"* ]] || false
	assert_nothing_created
}

@test "a template name that only prefixes a listed one is not found" {
	run --separate-stderr "$SCRIPT" start --template implement --branch b <<<"task"
	[ "$status" -eq 4 ]
	assert_nothing_created
}

@test "a failing hc templates exits 4 and creates nothing" {
	HC_STUB_TEMPLATES_EXIT=1 HC_STUB_TEMPLATES="" run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"hc templates failed"* ]] || false
	assert_nothing_created
}

@test "--template without a value, or an empty one, exits 2" {
	run --separate-stderr "$SCRIPT" start --branch b --template <<<"task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" start --branch b --template= <<<"task"
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "--harness, --model and --effort are gone" {
	for f in --harness=claude --model=opus --effort=high; do
		run --separate-stderr "$SCRIPT" start --branch b "$f" <<<"task"
		[ "$status" -eq 2 ]
		[[ "$stderr" == *"unknown flag"* ]] || false
	done
	assert_nothing_created
}

@test "a task hc reports as sent gives task_sent true, reason null and exit 0" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -c '[.task_sent, .reason]')" = '[true,null]' ]
}

@test "a task hc didn't send exits 6, keeps the terminal and worktree, and reports hc's reason" {
	HC_STUB_OUTPUT='{"address":"t9z","name":"b","first_message":{"sent":false,"reason":"blocked (permission) \"trust\"","started":null,"turn":null}}' \
		run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 6 ]
	[ "$(printf '%s' "$output" | jq -c '[.terminal, .task_sent, .reason]')" = '["t9z",false,"blocked (permission) \"trust\""]' ]
	[ -d "$WT" ]
	[[ "$stderr" == *"task not sent to t9z"* ]] || false
	[[ "$stderr" == *'blocked (permission) "trust"'* ]] || false
	[[ "$stderr" != *"git worktree remove"* ]] || false
}

@test "hc output without first_message counts as a task not sent" {
	HC_STUB_OUTPUT='{"address":"t9z","name":"b"}' run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 6 ]
	[ "$(printf '%s' "$output" | jq -r .task_sent)" = "false" ]
	[ "$(printf '%s' "$output" | jq -r .reason)" != "null" ]
}

@test "no Harness binary is needed on PATH" {
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
}

@test "the shipped templates have frontmatter, pre-allow hc, and carry the fixed rules" {
	dir="$BATS_TEST_DIRNAME/../templates"
	for name in implementer implementer-codex; do
		f="$dir/$name.md"
		[ -f "$f" ]
		[ "$(sed -n 1p "$f")" = "---" ]
		grep -qx "name: $name" "$f"
		grep -q '^description: ' "$f"
		for rule in "only in this worktree" "Do not start other agents" "Commit" \
			"write it to a file" "when you are done or stuck" "subagent.pr"; do
			grep -q "$rule" "$f"
		done
	done
	# Claude Code allows the two commands by name.
	cmd="$(sed -n 's/^command: //p' "$dir/implementer.md")"
	[[ "$cmd" == "claude "* ]] || false
	[[ "$cmd" == *"'Bash(hc send:*)'"* ]] || false
	[[ "$cmd" == *"'Bash(hc label:*)'"* ]] || false
	# Codex has no command-line allow rule: hc needs its socket, which the
	# workspace-write sandbox blocks without network access.
	cmd="$(sed -n 's/^command: //p' "$dir/implementer-codex.md")"
	[[ "$cmd" == "codex --no-daemon "* ]] || false
	[[ "$cmd" == *"-s workspace-write"* ]] || false
	[[ "$cmd" == *"sandbox_workspace_write.network_access=true"* ]] || false
}

@test "help start explains --template and where templates come from" {
	run --separate-stderr "$SCRIPT" help start
	[ "$status" -eq 0 ]
	# shellcheck disable=SC2088 # the help shows ~ literally
	for s in "--template <name>" "default: implementer" "hc templates" \
		"~/.config/herdr-core/templates" "templates/implementer.md" "6 "; do
		[[ "$output" == *"$s"* ]] || false
	done
	for s in "--harness" "--model" "--effort"; do
		[[ "$output" != *"$s"* ]] || false
	done
}
