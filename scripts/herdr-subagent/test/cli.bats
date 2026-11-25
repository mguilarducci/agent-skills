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

@test "help, help run, -h and --help print help on stdout and exit 0" {
	for args in "help" "help run" "-h" "--help" "run --help" "run -h"; do
		# shellcheck disable=SC2086
		run --separate-stderr "$SCRIPT" $args
		[ "$status" -eq 0 ]
		[ -z "$stderr" ]
		[[ "$output" == *"Examples:"* ]] || false
		[[ "$output" == *"https://github.com/mguilarducci/agent-skills/issues" ]] || false
	done
}

@test "help leads with examples" {
	run --separate-stderr "$SCRIPT" help run
	[[ "$(printf '%s\n' "$output" | sed -n '3p')" == "Examples:" ]] || false
}

@test "help run documents the run flags" {
	run --separate-stderr "$SCRIPT" help run
	[[ "$output" == *"--branch <name>"* ]] || false
	[[ "$output" == *"--base <branch>"* ]] || false
}

@test "--help wins over everything else" {
	run --separate-stderr "$SCRIPT" run --bogus --help -- "task"
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
	[[ "$stderr" == *"herdr-subagent run --help"* ]] || false
}

@test "missing task prints short help on stderr and exits 2" {
	for args in "run --branch b" "run --branch b --"; do
		# shellcheck disable=SC2086
		run --separate-stderr "$SCRIPT" $args
		[ "$status" -eq 2 ]
		[ -z "$output" ]
		[[ "$stderr" == *"herdr-subagent run --help"* ]] || false
	done
	assert_nothing_created
}

@test "unknown subcommand, unknown flag and extra positional exit 2" {
	run --separate-stderr "$SCRIPT" launch
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" help nope
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" run --branch b --nope x -- "task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" run --branch b extra -- "task"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" run --branch b -- "task" "extra"
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" --branch b run -- "task"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"herdr-subagent run --help"* ]] || false
	assert_nothing_created
}

@test "a flag without its value exits 2" {
	run --separate-stderr "$SCRIPT" run --branch
	[ "$status" -eq 2 ]
	run --separate-stderr "$SCRIPT" run --branch -- "task"
	[ "$status" -eq 2 ]
	assert_nothing_created
}
