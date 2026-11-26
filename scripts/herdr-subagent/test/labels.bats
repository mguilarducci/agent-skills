#!/usr/bin/env bats
# The labels a Herdr subagent is tagged with, with hc stubbed.

load test_helper

setup() {
	setup_sandbox
}

@test "every Herdr subagent gets subagent.repo, subagent.branch and subagent.base" {
	git push -q origin main:develop
	run --separate-stderr "$SCRIPT" start --branch feat/x --base develop <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_flag_values --label)" = "$(printf '%s\n' \
		"subagent.repo=$REPO" subagent.branch=feat/x subagent.base=develop)" ]
	[ "$(printf '%s' "$output" | jq -c .labels)" = \
		"{\"subagent.repo\":\"$REPO\",\"subagent.branch\":\"feat/x\",\"subagent.base\":\"develop\"}" ]
	[ "$(printf '%s' "$output" | jq -c .issue)" = "null" ]
}

@test "subagent.repo is the main checkout even when started from a linked worktree" {
	git worktree add -q -b other "$SANDBOX/elsewhere" main
	cd "$SANDBOX/elsewhere"
	run --separate-stderr "$SCRIPT" start --branch b <<<"task"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.labels["subagent.repo"]')" = "$REPO" ]
}

@test "--issue adds subagent.issue and the issue to the JSON" {
	run --separate-stderr "$SCRIPT" start --branch b --issue 48 <<<"task"
	[ "$status" -eq 0 ]
	hc_flag_values --label | grep -qx 'subagent.issue=48'
	[ "$(printf '%s' "$output" | jq -c .issue)" = "48" ]
	[ "$(printf '%s' "$output" | jq -r '.labels["subagent.issue"]')" = "48" ]
}

@test "leading zeros in --issue are dropped, so the JSON stays valid" {
	run --separate-stderr "$SCRIPT" start --branch b --issue 048 <<<"task"
	[ "$status" -eq 0 ]
	hc_flag_values --label | grep -qx 'subagent.issue=48'
	[ "$(printf '%s' "$output" | jq -c .issue)" = "48" ]
}

@test "a non-numeric --issue exits 2 with nothing created" {
	for bad in 48a '#48' '' ' 4' -1 4.2 0 00; do
		run --separate-stderr "$SCRIPT" start --branch b "--issue=$bad" <<<"task"
		[ "$status" -eq 2 ]
		assert_nothing_created
	done
}

@test "repeatable --label k=v is passed through and listed in the JSON" {
	run --separate-stderr "$SCRIPT" start --branch b --label batch=demo --label=mg.note='a b=c' <<<"task"
	[ "$status" -eq 0 ]
	[ "$(hc_flag_values --label | tail -n 2)" = "$(printf '%s\n' batch=demo 'mg.note=a b=c')" ]
	[ "$(printf '%s' "$output" | jq -r .labels.batch)" = "demo" ]
	[ "$(printf '%s' "$output" | jq -r '.labels["mg.note"]')" = "a b=c" ]
	[ "$(printf '%s' "$output" | jq '.labels | length')" -eq 5 ]
}

@test "a malformed label exits 2 with nothing created" {
	for bad in nokey =v k= '' 'k v=1' 'k"=v'; do
		run --separate-stderr "$SCRIPT" start --branch b --label "$bad" <<<"task"
		[ "$status" -eq 2 ]
		assert_nothing_created
	done
}

@test "a label under subagent., herdr. or where exits 2 with nothing created" {
	for bad in subagent.repo=x subagent.pr=1 herdr.space=s where=x where.x=y; do
		run --separate-stderr "$SCRIPT" start --branch b --label "$bad" <<<"task"
		[ "$status" -eq 2 ]
		[[ "$stderr" == *"reserved"* ]] || false
		assert_nothing_created
	done
}

@test "the same label key twice exits 2 with nothing created" {
	run --separate-stderr "$SCRIPT" start --branch b --label k=1 --label k=2 <<<"task"
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "the template and cwd are not copied into labels" {
	run --separate-stderr "$SCRIPT" start --branch b --template implementer-codex <<<"task"
	[ "$status" -eq 0 ]
	if hc_flag_values --label | grep -q -e implementer-codex -e "$REPO/.worktrees"; then false; fi
}
