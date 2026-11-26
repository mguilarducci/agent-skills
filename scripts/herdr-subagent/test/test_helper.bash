# Shared setup for herdr-subagent bats tests.
# Tests drive the script as a process: a stubbed `hc` on PATH and a
# throwaway git repo with a bare origin. The real `hc` is never reachable.

bats_require_minimum_version 1.5.0

# shellcheck disable=SC2034 # used by the .bats files
SCRIPT="$BATS_TEST_DIRNAME/../herdr-subagent.sh"

setup_sandbox() {
	SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/sandbox"
	STUBS="$SANDBOX/stubs"
	HC_LOG="$SANDBOX/hc-log"
	mkdir -p "$STUBS" "$HC_LOG"

	# hc stub: records each argv element in its own file (arg.1, arg.2, ...),
	# prints $HC_STUB_OUTPUT and exits with $HC_STUB_EXIT.
	# `hc ls` is answered from $HC_STUB_LS (default: no terminals) and only
	# counted in $HC_LOG/ls-calls, so it never clobbers the `hc run` argv.
	# `hc templates` is answered from $HC_STUB_TEMPLATES (default:
	# implementer-claude, implementer-codex and reviewer-claude) and only counted in $HC_LOG/templates-calls.
	# `hc get <t>` is answered from $HC_STUB_GET (default: a live terminal
	# whose address is <t>), exits $HC_STUB_GET_EXIT, and is only logged in
	# $HC_LOG/get-calls.
	# `hc kill <t>` and `hc rm <t>` are only logged in $HC_LOG/kill-calls and
	# $HC_LOG/rm-calls, and exit $HC_STUB_KILL_EXIT and $HC_STUB_RM_EXIT.
	cat >"$STUBS/hc" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "templates" ]; then
	printf '%s\n' "$*" >>"$HC_LOG/templates-calls"
	if [ -n "${HC_STUB_TEMPLATES+x}" ]; then
		printf '%s\n' "$HC_STUB_TEMPLATES"
	else
		printf '%s\n' '{"templates":[{"name":"implementer-claude","description":"d","command":"claude","error":null},{"name":"implementer-codex","description":"d","command":"codex --no-daemon","error":null},{"name":"reviewer-claude","description":"d","command":"claude","error":null}]}'
	fi
	exit "${HC_STUB_TEMPLATES_EXIT:-0}"
fi
if [ "${1:-}" = "get" ]; then
	printf '%s\n' "$*" >>"$HC_LOG/get-calls"
	if [ -n "${HC_STUB_GET+x}" ]; then
		printf '%s\n' "$HC_STUB_GET"
	else
		printf '{"address":"%s","state":"live","parent":null}\n' "${2:-}"
	fi
	exit "${HC_STUB_GET_EXIT:-0}"
fi
if [ "${1:-}" = "kill" ] || [ "${1:-}" = "rm" ]; then
	printf '%s\n' "$*" >>"$HC_LOG/$1-calls"
	if [ "$1" = "kill" ]; then exit "${HC_STUB_KILL_EXIT:-0}"; fi
	exit "${HC_STUB_RM_EXIT:-0}"
fi
if [ "${1:-}" = "ls" ]; then
	printf '%s\n' "$*" >>"$HC_LOG/ls-calls"
	if [ -n "${HC_STUB_LS+x}" ]; then
		printf '%s\n' "$HC_STUB_LS"
	else
		printf '%s\n' '{"terminals":[]}'
	fi
	exit "${HC_STUB_LS_EXIT:-0}"
fi
n=0
for a in "$@"; do
	n=$((n + 1))
	printf '%s' "$a" >"$HC_LOG/arg.$n"
done
printf '%s\n' "$n" >"$HC_LOG/argc"
if [ -n "${HC_STUB_OUTPUT+x}" ]; then
	printf '%s\n' "$HC_STUB_OUTPUT"
else
	printf '%s\n' '{"address":"t9z","name":"stub","state":"live","first_message":{"sent":true,"reason":null,"started":true,"turn":1}}'
fi
exit "${HC_STUB_EXIT:-0}"
STUB
	chmod +x "$STUBS/hc"

	export HC_LOG
	export PATH="$STUBS:/usr/bin:/bin"
	export HC_TERMINAL_ID="tparent"
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

	git init -q --bare "$SANDBOX/origin.git"
	git -C "$SANDBOX/origin.git" symbolic-ref HEAD refs/heads/main
	git clone -q "$SANDBOX/origin.git" "$SANDBOX/repo" 2>/dev/null
	REPO="$SANDBOX/repo"
	git -C "$REPO" checkout -q -b main 2>/dev/null || true
	git -C "$REPO" commit -q --allow-empty -m init
	git -C "$REPO" push -q origin main
	cd "$REPO" || return 1
}

# The argv the hc stub received, one element per line.
hc_argv() {
	local i=1 argc
	argc="$(cat "$HC_LOG/argc")"
	while [ "$i" -le "$argc" ]; do
		printf '%s\n' "$(cat "$HC_LOG/arg.$i")"
		i=$((i + 1))
	done
}

# The values hc run got for flag $1 (such as --label), one per line, from
# the flags before `--`.
hc_flag_values() {
	local i=1 argc a
	argc="$(cat "$HC_LOG/argc")"
	while [ "$i" -lt "$argc" ]; do
		a="$(cat "$HC_LOG/arg.$i")"
		[ "$a" != "--" ] || return 0
		if [ "$a" = "$1" ]; then
			printf '%s\n' "$(cat "$HC_LOG/arg.$((i + 1))")"
		fi
		i=$((i + 1))
	done
}

# The template hc run got: the argv element right after `--`.
hc_template() {
	local i=1 argc
	argc="$(cat "$HC_LOG/argc")"
	while [ "$i" -lt "$argc" ]; do
		if [ "$(cat "$HC_LOG/arg.$i")" = "--" ]; then
			cat "$HC_LOG/arg.$((i + 1))"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# The n-th argv element the hc stub received (1-based).
hc_arg() {
	cat "$HC_LOG/arg.$1"
}

assert_nothing_created() {
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git -C "$REPO" branch --format='%(refname:short)')" = "main" ]
}

# The task text hc run got: the argv element after the template.
hc_task_text() {
	cat "$HC_LOG/arg.$(cat "$HC_LOG/argc")"
}

# The text start sends for the implementer role: the shipped rules, a blank
# line, a Task: heading and the task.
implementer_text() {
	printf '%s\n\nTask:\n%s' "$(cat "$BATS_TEST_DIRNAME/../rules/implementer.md")" "$1"
}
