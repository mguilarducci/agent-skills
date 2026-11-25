# Shared setup for herdr-subagent bats tests.
# Tests drive the script as a process: stubbed `hc`/`claude` on PATH and a
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
	cat >"$STUBS/hc" <<'STUB'
#!/bin/bash
n=0
for a in "$@"; do
	n=$((n + 1))
	printf '%s' "$a" >"$HC_LOG/arg.$n"
done
printf '%s\n' "$n" >"$HC_LOG/argc"
if [ -n "${HC_STUB_OUTPUT+x}" ]; then
	printf '%s\n' "$HC_STUB_OUTPUT"
else
	printf '%s\n' '{"address":"t9z","name":"stub","state":"live"}'
fi
exit "${HC_STUB_EXIT:-0}"
STUB
	printf '#!/bin/bash\nexit 0\n' >"$STUBS/claude"
	chmod +x "$STUBS/hc" "$STUBS/claude"

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

# The n-th argv element the hc stub received (1-based).
hc_arg() {
	cat "$HC_LOG/arg.$1"
}

assert_nothing_created() {
	[ ! -e "$REPO/.worktrees" ]
	[ ! -e "$HC_LOG/argc" ]
	[ "$(git -C "$REPO" branch --format='%(refname:short)')" = "main" ]
}
