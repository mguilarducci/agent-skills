#!/usr/bin/env bats
# Command surface: help, version and usage errors.

load test_helper

setup() {
	setup_sandbox
}

@test "--version prints the version on stdout" {
	run --separate-stderr "$SCRIPT" --version
	[ "$status" -eq 0 ]
	[ "$output" = "herdr-subagent 0.1.0" ]
}

@test "help, help start, -h and --help print help on stdout and exit 0" {
	for args in "help" "help start" "-h" "--help" "start --help" "start -h"; do
		# shellcheck disable=SC2086
		run --separate-stderr "$SCRIPT" $args
		[ "$status" -eq 0 ]
		[ -z "$stderr" ]
		[[ "$output" == *"Examples:"* ]] || false
		[[ "$output" == *"https://github.com/mguilarducci/agent-skills/issues" ]] || false
	done
}

@test "help leads with examples" {
	run --separate-stderr "$SCRIPT" help start
	[[ "$(printf '%s\n' "$output" | sed -n '3p')" == "Examples:" ]] || false
}

@test "help start documents the start flags and the stdin task" {
	run --separate-stderr "$SCRIPT" help start
	[[ "$output" == *"--branch <name>"* ]] || false
	[[ "$output" == *"--base <branch>"* ]] || false
	[[ "$output" == *"start --branch fix/docs <<'EOF'"* ]] || false
	[[ "$output" == *"stdin"* ]] || false
}

@test "help no longer mentions the removed v1 surface" {
	for args in "help" "help start"; do
		# shellcheck disable=SC2086
		run --separate-stderr "$SCRIPT" $args
		# "herdr-subagent run", not `hc run --bg`, which help does mention.
		for s in "--json" "--dry-run" "--task-file" "herdr-subagent run " "-- \""; do
			[[ "$output" != *"$s"* ]] || false
		done
	done
}

@test "run is no longer a subcommand, nor a help topic" {
	run --separate-stderr "$SCRIPT" run --branch b <<<"task"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown subcommand: run"* ]] || false
	run --separate-stderr "$SCRIPT" help run
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "--help wins over everything else" {
	run --separate-stderr "$SCRIPT" start --bogus --help </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"--branch <name>"* ]] || false
	run --separate-stderr "$SCRIPT" nope --version --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Examples:"* ]] || false
	assert_nothing_created
}

@test "missing subcommand prints short help on stderr and exits 2" {
	run --separate-stderr "$SCRIPT"
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ "$stderr" == *"herdr-subagent start --help"* ]] || false
}

@test "unknown subcommand, unknown flag and extra positional exit 2" {
	run --separate-stderr "$SCRIPT" launch
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" help nope
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" start --branch b --nope x <<<"task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" start --branch b extra <<<"task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" --branch b start <<<"task"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"herdr-subagent start --help"* ]] || false
	assert_nothing_created
}

@test "removed v1 flags and a task after -- exit 2" {
	for args in "--json" "--dry-run" "-n" "--task-file -" "--task-file=-"; do
		# shellcheck disable=SC2086
		run --separate-stderr "$SCRIPT" start --branch b $args <<<"task"
		[ "$status" -eq 2 ]
		[ -z "$output" ]
	done
	run --separate-stderr "$SCRIPT" start --branch b -- "task" </dev/null
	[ "$status" -eq 2 ]
	assert_nothing_created
}

@test "help, help close and close --help show the full help, close included" {
	for args in "--help" "help" "help close" "close --help" "close b -h" "start --help"; do
		# shellcheck disable=SC2086
		run --separate-stderr "$SCRIPT" $args
		[ "$status" -eq 0 ]
		[ -z "$stderr" ]
		[[ "$output" == *"herdr-subagent start [flags] <<'EOF'"* ]] || false
		[[ "$output" == *"herdr-subagent close <branch>"* ]] || false
	done
	assert_nothing_created
}

@test "--help shows both JSON shapes" {
	run --separate-stderr "$SCRIPT" --help
	[[ "$output" == *'{"terminal","name","branch","base","worktree","template","issue",'* ]] || false
	[[ "$output" == *'"labels","task_sent","reason"}'* ]] || false
	[[ "$output" == *'{"branch","worktree","terminal_removed","worktree_removed",'* ]] || false
	[[ "$output" == *'"branch_deleted","branch_kept_reason"}'* ]] || false
}

@test "--help has an exit-code row for each code of start and close" {
	run --separate-stderr "$SCRIPT" --help
	table="$(printf '%s\n' "$output" | sed -n '/^Exit codes/,/^$/p')"
	[[ "$table" == *"start"*"close"* ]] || false
	for code in 0 1 2 3 4 5 6 130; do
		printf '%s\n' "$table" | grep -Eq "^  $code +[a-z]" || {
			echo "no exit-code row for $code" >&2
			false
		}
	done
}

@test "--help has a Tips for agents section covering the supervision loop" {
	run --separate-stderr "$SCRIPT" --help
	tips="$(printf '%s\n' "$output" | sed -n '/^Tips for agents:/,/^Report issues:/p')"
	[ -n "$tips" ]
	for s in "<<'EOF'" "hc wait --children any" "claims" "Exit 6" \
		"permission prompt" "Exit 5" "hc ls --label subagent.repo=" \
		"merged" ".worktrees/"; do
		[[ "$tips" == *"$s"* ]] || {
			echo "tips miss: $s" >&2
			false
		}
	done
}

@test "a flag without its value exits 2" {
	run --separate-stderr "$SCRIPT" start --branch <<<"task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" start --branch -- <<<"task"
	[ "$status" -eq 2 ]
	assert_nothing_created
}
