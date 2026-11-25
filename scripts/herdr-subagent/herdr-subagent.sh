#!/usr/bin/env bash
# herdr-subagent: launch a Claude Herdr subagent in its own worktree.
#
# Runs on macOS's stock bash 3.2: no associative arrays, no ${x,,}.
# Needs only git, hc and claude (or codex) at runtime.

set -u

VERSION="0.1.0"
PROG="herdr-subagent"
ISSUES_URL="https://github.com/mguilarducci/agent-skills/issues"

# --- help --------------------------------------------------------------------

print_main_help() {
	cat <<EOF
$PROG - launch a Claude Herdr subagent in its own worktree

Examples:
  t=\$($PROG run --branch feat/login -- "Add OAuth login")
  $PROG run --base develop --branch fix/parser -- "Fix the v1.2 parser"
  hc wait "\$t"

Usage:
  $PROG run [flags] -- "<task>"
  $PROG help [run]
  $PROG --version

Commands:
  run    Create a worktree on a new branch and start Claude in it through hc
  help   Show this help; \`help run\` shows the run flags

Flags:
  -h, --help   Show help
  --version    Print the version

Report issues: $ISSUES_URL
EOF
}

# The indented "EOF" below is example text, not the end token.
# shellcheck disable=SC1039
print_run_help() {
	cat <<EOF
$PROG run - start a Claude Herdr subagent in a new worktree

Examples:
  t=\$($PROG run --branch feat/login -- "Add OAuth login")
  $PROG run --base develop --branch fix/parser -- "Fix the v1.2 parser"
  $PROG run --branch=issue-6 -- "Implement issue #6"
  $PROG run --harness codex --effort high --branch fix/ci -- "Fix CI"
  $PROG run --branch fix/docs --task-file - <<'EOF'
  Fix the "quoted" \$HOME and \`backtick\` bits in the docs.
  EOF

Usage:
  $PROG run [flags] -- "<task>"
  $PROG run [flags] --task-file <path|->

Flags:
  --branch <name>   New branch for the worktree (required).
                    ASCII letters, digits and . _ / - only.
  --base <branch>   Existing local branch to start from (default: main).
  --harness <claude|codex>
                    Agent to start (default: claude).
  --model <s>       Passed as-is: claude --model <s>, codex -m <s>.
  --effort <s>      Passed as-is: claude --effort <s>,
                    codex -c model_reasoning_effort=<s>.
                    Left out, the harness's own config applies.
  --task-file <path|->
                    Read the task from a file, or from stdin with -,
                    instead of after --. Trailing newlines are dropped.
  --json            Print one JSON object on stdout instead of the id:
                    {"terminal","name","branch","base","worktree",
                    "harness","model"}; model is null without --model.
  -h, --help        Show this help.

Flags take \`--flag value\` or \`--flag=value\`, in any order before \`--\`.

The worktree goes to <main-checkout-root>/.worktrees/<slug(branch)>.
stdout carries only the Herdr subagent's terminal id (or the --json
object); progress, errors and the summary go to stderr.

Exit codes:
  0    launched
  1    git or hc failed after work started (leftovers are printed)
  2    usage error; nothing was created
  4    missing git repo, hc, the chosen harness or \$HC_TERMINAL_ID;
       nothing was created
  5    branch, worktree path or hc name already exists; nothing was created:
       pick another name and retry (an existing branch is never reused)
  130  interrupted

Report issues: $ISSUES_URL
EOF
}

print_short_help() {
	cat <<EOF
Usage: $PROG run [flags] -- "<task>"

Examples:
  $PROG run --branch feat/login -- "Add OAuth login"
  $PROG run --base develop --branch fix/parser -- "Fix the v1.2 parser"

See \`$PROG run --help\`.
EOF
}

# --- errors ------------------------------------------------------------------

say() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

usage_error() {
	say "$1"
	printf '\n' >&2
	print_short_help >&2
	exit 2
}

die() {
	local code="$1"
	shift
	say "$*"
	exit "$code"
}

# --- naming ------------------------------------------------------------------

# Each run of chars outside [A-Za-z0-9._-] becomes "-", then "-" is trimmed.
slugify() {
	printf '%s' "$1" | LC_ALL=C sed -e 's/[^A-Za-z0-9._-][^A-Za-z0-9._-]*/-/g' -e 's/^-*//' -e 's/-*$//'
}

# Lowercase, map anything outside a-z0-9-_ to "-", trim, cut to 32, trim.
hc_name_for() {
	# ASCII only on purpose: the hc name allows only a-z 0-9 - _.
	# shellcheck disable=SC2018,SC2019
	printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' |
		LC_ALL=C sed -e 's/[^a-z0-9_-]/-/g' -e 's/^-*//' -e 's/-*$//' |
		cut -c1-32 |
		sed -e 's/^-*//' -e 's/-*$//'
}

# --- conflicts ---------------------------------------------------------------

taken() {
	say "already exists: $1"
	say "pick another --branch and retry"
	exit 5
}

# Exits 5 if the branch, the worktree path or the hc name is already taken.
# An existing branch is never reused.
refuse_taken_names() {
	local branch="$1" wt_path="$2" hc_name="$3"
	git show-ref --verify --quiet "refs/heads/$branch" &&
		taken "local branch $branch"
	# Only what is already known locally: no fetch just for this check.
	git show-ref --verify --quiet "refs/remotes/origin/$branch" &&
		taken "remote branch origin/$branch"
	# Also catches two branches with the same slug (feat/x, feat-x).
	if [ -e "$wt_path" ] || [ -L "$wt_path" ]; then
		taken "worktree path $wt_path"
	fi
	# `hc run --name` must be unique among live terminals (plain `hc ls`).
	local live
	live="$(hc ls --json)" || die 1 "hc ls failed; nothing was created"
	if printf '%s\n' "$live" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' |
		sed 's/.*"\([^"]*\)"$/\1/' | grep -qxF -- "$hc_name"; then
		taken "live hc terminal named $hc_name"
	fi
	return 0
}

# Warns only: never writes .gitignore or .git/info/exclude.
warn_if_worktrees_not_ignored() {
	local root="$1"
	git -C "$root" check-ignore -q .worktrees/ && return 0
	say "warning: .worktrees/ is not ignored in $root; to ignore it, run one of:"
	printf "  echo '.worktrees/' >> .gitignore            (shared, committed)\n" >&2
	printf "  echo '.worktrees/' >> .git/info/exclude     (only you)\n" >&2
}

# --- leftovers ---------------------------------------------------------------

# Set once work starts; used to report what was left behind on failure.
WT_PATH=""
BRANCH=""
BRANCH_EXISTED=1
PATH_EXISTED=1

print_leftovers() {
	local left=0
	if [ "$PATH_EXISTED" -eq 0 ] && [ -n "$WT_PATH" ] && [ -e "$WT_PATH" ]; then
		say "worktree left at $WT_PATH"
		printf '  git worktree remove %s\n' "$WT_PATH" >&2
		left=1
	fi
	if [ "$BRANCH_EXISTED" -eq 0 ] && [ -n "$BRANCH" ] &&
		git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
		[ "$left" -eq 1 ] || say "branch left behind: $BRANCH"
		printf '  git branch -d %s\n' "$BRANCH" >&2
	fi
}

fail_after_start() {
	say "$*"
	print_leftovers
	exit 1
}

on_interrupt() {
	trap - INT
	printf '\n' >&2
	say "interrupted"
	print_leftovers
	exit 130
}

# --- json --------------------------------------------------------------------

# Prints $1 as a quoted JSON string: escapes \ and ", and every control char.
json_str() {
	local s="$1" i c
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	case "$s" in
	*[[:cntrl:]]*)
		i=1
		while [ "$i" -le 31 ]; do
			# shellcheck disable=SC2059 # the octal escape must be in the format
			c="$(printf "\\$(printf '%03o' "$i")")"
			s="${s//"$c"/$(printf '\\u%04x' "$i")}"
			i=$((i + 1))
		done
		s="${s//$'\177'/\\u007f}"
		;;
	esac
	printf '"%s"' "$s"
}

# --- task file -------------------------------------------------------------

# Sets $task from a file, or from stdin for "-". Trailing newlines are dropped
# (a heredoc always ends with one).
read_task_file() {
	local f="$1"
	if [ "$f" != "-" ]; then
		[ -f "$f" ] && [ -r "$f" ] || usage_error "cannot read --task-file: $f"
	fi
	task="$(cat -- "$f")" || usage_error "cannot read --task-file: $f"
}

# --- run ---------------------------------------------------------------------

cmd_run() {
	local base="main" branch="" task="" have_task=0 arg
	local harness="claude" model="" effort="" have_model=0 have_effort=0
	local task_file="" have_task_file=0 json=0

	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
		--)
			shift
			[ "$#" -le 1 ] || usage_error "unexpected argument after the task: $2"
			if [ "$#" -eq 1 ]; then
				task="$1"
				have_task=1
			fi
			break
			;;
		--base=*) base="${arg#--base=}" ;;
		--branch=*) branch="${arg#--branch=}" ;;
		--harness=*) harness="${arg#--harness=}" ;;
		--task-file=*)
			task_file="${arg#--task-file=}"
			have_task_file=1
			;;
		--json) json=1 ;;
		--model=*)
			model="${arg#--model=}"
			have_model=1
			;;
		--effort=*)
			effort="${arg#--effort=}"
			have_effort=1
			;;
		--base | --branch | --harness | --model | --effort | --task-file)
			if [ "$#" -lt 2 ] || [ "$2" = "--" ]; then
				usage_error "$arg needs a value"
			fi
			case "$arg" in
			--base) base="$2" ;;
			--branch) branch="$2" ;;
			--harness) harness="$2" ;;
			--task-file)
				task_file="$2"
				have_task_file=1
				;;
			--model)
				model="$2"
				have_model=1
				;;
			--effort)
				effort="$2"
				have_effort=1
				;;
			esac
			shift
			;;
		-*) usage_error "unknown flag: $arg" ;;
		*) usage_error "unexpected argument: $arg (put the task after --)" ;;
		esac
		shift
	done

	if [ "$have_task_file" -eq 1 ]; then
		[ "$have_task" -eq 0 ] || usage_error "give the task either after -- or with --task-file, not both"
		read_task_file "$task_file"
		[ -n "$task" ] || usage_error "empty task in --task-file: $task_file"
	fi
	[ "$have_task" -eq 1 ] || [ "$have_task_file" -eq 1 ] || usage_error "missing task"
	[ -n "$task" ] || usage_error "missing task"
	[ -n "$branch" ] || usage_error "missing --branch"
	[ -n "$base" ] || usage_error "--base needs a value"
	case "$harness" in
	claude | codex) ;;
	*) usage_error "unknown --harness (claude or codex): $harness" ;;
	esac

	command -v git >/dev/null 2>&1 || die 4 "git not found on PATH"

	# grep under LC_ALL=C matches bytes, so non-ASCII never passes.
	if printf '%s' "$branch" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
		usage_error "invalid branch name (ASCII letters, digits and . _ / - only): $branch"
	fi
	git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
		usage_error "invalid branch name: $branch"

	local slug hc_name
	slug="$(slugify "$branch")"
	[ -n "$slug" ] || usage_error "branch name gives an empty slug: $branch"
	hc_name="$(hc_name_for "$slug")"
	[ -n "$hc_name" ] || usage_error "branch name gives an empty hc name: $branch"

	git rev-parse --git-dir >/dev/null 2>&1 || die 4 "not inside a git repository"
	command -v hc >/dev/null 2>&1 || die 4 "hc not found on PATH"
	command -v "$harness" >/dev/null 2>&1 || die 4 "$harness not found on PATH"
	[ -n "${HC_TERMINAL_ID:-}" ] || die 4 "HC_TERMINAL_ID is not set (run this from a Herdr terminal)"
	local parent_id="$HC_TERMINAL_ID"

	git show-ref --verify --quiet "refs/heads/$base" ||
		usage_error "--base must name an existing local branch: $base"

	local common root
	common="$(git rev-parse --path-format=absolute --git-common-dir)" ||
		die 4 "cannot find the main checkout"
	root="$(dirname "$common")"
	local wt_path="$root/.worktrees/$slug"

	refuse_taken_names "$branch" "$wt_path" "$hc_name"
	warn_if_worktrees_not_ignored "$root"

	# Work starts here: from now on, failures may leave things behind.
	WT_PATH="$wt_path"
	BRANCH="$branch"
	if git show-ref --verify --quiet "refs/heads/$branch"; then BRANCH_EXISTED=1; else BRANCH_EXISTED=0; fi
	if [ -e "$wt_path" ]; then PATH_EXISTED=1; else PATH_EXISTED=0; fi
	trap on_interrupt INT

	say "creating worktree $wt_path on new branch $branch from $base"
	git worktree add -b "$branch" "$wt_path" "$base" >&2 ||
		fail_after_start "git worktree add failed"

	local text
	text="$(printf '%s\n\n%s\n%s\n%s' "$task" \
		"Work only in this worktree ($wt_path, branch $branch). Do not start other agents." \
		"Report with hc send $parent_id \"<result or blocker>\" when done or stuck, not just to acknowledge." \
		"Write long answers to a file and send its path.")"

	# Never empty: bash 3.2 with set -u rejects "${a[@]}" on an empty array.
	local cmd
	if [ "$harness" = "codex" ]; then
		cmd=(codex --no-daemon)
		[ "$have_model" -eq 0 ] || cmd+=(-m "$model")
		[ "$have_effort" -eq 0 ] || cmd+=(-c "model_reasoning_effort=$effort")
	else
		cmd=(claude)
		[ "$have_model" -eq 0 ] || cmd+=(--model "$model")
		[ "$have_effort" -eq 0 ] || cmd+=(--effort "$effort")
	fi

	say "starting $harness as $hc_name"
	local out
	out="$(hc run --bg --name "$hc_name" --cwd "$wt_path" "${cmd[@]}" -- "$text")" ||
		fail_after_start "hc run failed"

	# Piped, hc prints JSON; take its "address". Fall back to a bare id.
	local t
	t="$(printf '%s\n' "$out" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	if [ -z "$t" ]; then
		case "$out" in
		*[!A-Za-z0-9/_-]* | "") ;;
		*) t="$out" ;;
		esac
	fi
	[ -n "$t" ] || fail_after_start "could not read the terminal id from hc run: $out"

	trap - INT
	if [ "$json" -eq 1 ]; then
		local model_json="null"
		[ "$have_model" -eq 0 ] || model_json="$(json_str "$model")"
		printf '{"terminal":%s,"name":%s,"branch":%s,"base":%s,"worktree":%s,"harness":%s,"model":%s}\n' \
			"$(json_str "$t")" "$(json_str "$hc_name")" "$(json_str "$branch")" \
			"$(json_str "$base")" "$(json_str "$wt_path")" "$(json_str "$harness")" "$model_json"
	else
		printf '%s\n' "$t"
	fi
	print_summary "$t" "$hc_name" "$wt_path" "$branch" "$base" "$root" "$harness"
}

print_summary() {
	local t="$1" name="$2" wt_path="$3" branch="$4" base="$5" root="$6" harness="$7"
	{
		printf '\n'
		say "started Herdr subagent $t ($name)"
		printf '  worktree: %s\n' "$wt_path"
		printf '  branch:   %s (new, from %s)\n' "$branch" "$base"
		printf '\nNext:\n'
		printf '  hc read %s\n' "$t"
		printf '  hc send %s "<message>"\n' "$t"
		printf '  hc wait %s\n' "$t"
		printf '  hc kill %s\n' "$t"
		printf '\n'
	} >&2
	if [ "$harness" = "codex" ]; then
		print_codex_warning "$t" >&2
	else
		print_claude_warning "$root" >&2
	fi
}

print_codex_warning() {
	# Printed literally for the reader, not expanded.
	# shellcheck disable=SC2016
	printf '%s\n' 'Codex may ask before each `hc send`. To allow it for good, run:'
	printf '%s\n' '  mkdir -p ~/.codex/rules'
	printf '%s\n' "  echo 'prefix_rule(pattern=[\"hc\", \"send\"], decision=\"allow\")' >> ~/.codex/rules/default.rules"
	printf '%s\n' 'If Codex shows a trust dialog, open it with:'
	printf '  hc attach %s\n' "$1"
}

print_claude_warning() {
	local root="$1"
	# Printed literally for the reader, not expanded.
	# shellcheck disable=SC2088
	local user="~/.claude/settings.json"
	local proj="$root/.claude/settings.json"
	local local_="$root/.claude/settings.local.json"
	local w=${#user}
	[ "${#proj}" -le "$w" ] || w=${#proj}
	[ "${#local_}" -le "$w" ] || w=${#local_}

	{
		# shellcheck disable=SC2016 # literal backticks
		printf '%s\n' 'Claude may ask before each `hc send`. To allow it for good, add "Bash(hc send:*)" to permissions.allow in one of:'
		printf '  %-*s   (user: every project)\n' "$w" "$user"
		printf '  %-*s   (project: shared, committed)\n' "$w" "$proj"
		printf '  %-*s   (project: only you, not committed)\n' "$w" "$local_"
	} >&2
}

# --- main --------------------------------------------------------------------

main() {
	local arg seen_run=0
	# -h/--help wins over everything before "--".
	for arg in "$@"; do
		case "$arg" in
		--) break ;;
		run) seen_run=1 ;;
		-h | --help)
			if [ "$seen_run" -eq 1 ]; then print_run_help; else print_main_help; fi
			exit 0
			;;
		esac
	done

	[ "$#" -gt 0 ] || usage_error "missing subcommand"

	case "$1" in
	--version)
		[ "$#" -eq 1 ] || usage_error "unexpected argument: $2"
		printf '%s %s\n' "$PROG" "$VERSION"
		;;
	help)
		case "$#:${2:-}" in
		1:) print_main_help ;;
		2:run) print_run_help ;;
		*) usage_error "unknown help topic: ${2:-}" ;;
		esac
		;;
	run)
		shift
		cmd_run "$@"
		;;
	-*) usage_error "unknown flag: $1" ;;
	*) usage_error "unknown subcommand: $1" ;;
	esac
}

main "$@"
