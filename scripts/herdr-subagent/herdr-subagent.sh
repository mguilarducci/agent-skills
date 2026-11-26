#!/usr/bin/env bash
# herdr-subagent: launch a Herdr subagent from an hc template in its own worktree.
#
# Runs on macOS's stock bash 3.2: no associative arrays, no ${x,,}.
# Needs only git and hc at runtime; the Harness is the template's concern.

set -u

VERSION="0.1.0"
PROG="herdr-subagent"
ISSUES_URL="https://github.com/mguilarducci/agent-skills/issues"

# --- help --------------------------------------------------------------------

print_main_help() {
	cat <<HELP
$PROG - launch a Herdr subagent in its own worktree

Examples:
  $PROG start --branch feat/login <<'EOF'
  Add OAuth login.
  EOF

Usage:
  $PROG start [flags] <<'EOF'
  <task>
  EOF
  $PROG help [start]
  $PROG --version

Commands:
  start  Create a worktree on a new branch and start an hc template in
         it; the task is read from stdin
  help   Show this help; \`help start\` shows the start flags

Flags:
  -h, --help   Show help
  --version    Print the version

Report issues: $ISSUES_URL
HELP
}

print_start_help() {
	cat <<HELP
$PROG start - start a Herdr subagent in a new worktree

Examples:
  $PROG start --branch fix/docs <<'EOF'
  Fix the "quoted" \$HOME and \`backtick\` bits in the docs.
  EOF
  $PROG start --base develop --branch fix/parser <task.md
  $PROG start --template implementer-codex --branch fix/ci <<<"Fix CI"

Usage:
  $PROG start [flags] <<'EOF'
  <task>
  EOF

Flags:
  --branch <name>   New branch for the worktree (required).
                    ASCII letters, digits and . _ / - only.
  --base <branch>   Base branch: a branch on origin to start from
                    (default: main).
  --template <name> hc template to launch from (default: implementer).
  -h, --help        Show this help.

Flags take \`--flag value\` or \`--flag=value\`, in any order.

The task is read from stdin, byte-for-byte, trailing newlines included.
Use a quoted heredoc (<<'EOF') so quotes, \$ and backticks reach the
Herdr subagent unchanged. An empty or whitespace-only task, or stdin
attached to a terminal, exits 2.

start fetches <base> from origin and creates the new branch from
origin/<base>. No local branch is ever written. The worktree goes to
<main-checkout-root>/.worktrees/<slug(branch)>.

Templates: the Herdr subagent is started from an hc template and the task.
The template sets the Harness, model, effort, permissions and the child's
fixed rules; hc adds the report-back target, so the script sends only the
task. It must be listed by \`hc templates\`: a Markdown file in
~/.config/herdr-core/templates/<name>.md. This repo ships
scripts/herdr-subagent/templates/implementer.md (Claude Code) and
implementer-codex.md (Codex): copy or link them there. The script never
installs a template; a different setup is a different template.

stdout is always one JSON line:
  {"terminal","name","branch","base","worktree","template","task_sent","reason"}
reason is hc's reason when task_sent is false, null otherwise. stderr
carries only progress, errors, leftovers after a failure and one final
"started" line.

Exit codes:
  0    launched
  1    git or hc failed after work started (leftovers are printed)
  2    usage error, including a TTY or empty stdin; nothing was created
  3    no origin, a failed fetch, or <base> missing on origin; nothing
       was created
  4    missing git repo, hc (or a failing hc ls or hc templates), the
       template or \$HC_TERMINAL_ID; nothing was created
  5    branch, worktree path or hc name already exists; nothing was created:
       pick another name and retry (an existing branch is never reused)
  6    started, but hc did not deliver the task (task_sent false); the
       terminal and worktree are kept: read its screen, then send the task
  130  interrupted

Report issues: $ISSUES_URL
HELP
}

print_short_help() {
	cat <<HELP
Usage: $PROG start [flags] <<'EOF'
<task>
EOF

Example:
  $PROG start --branch feat/login <<<"Add OAuth login"

See \`$PROG start --help\`.
HELP
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

exit_name_taken() {
	say "already exists: $1"
	say "pick another --branch and retry"
	exit 5
}

# Exits 5 if the branch, the worktree path or the hc name is already taken.
# An existing branch is never reused.
refuse_taken_names() {
	local branch="$1" wt_path="$2" hc_name="$3"
	git show-ref --verify --quiet "refs/heads/$branch" &&
		exit_name_taken "local branch $branch"
	# Only what is already known locally: no fetch just for this check.
	git show-ref --verify --quiet "refs/remotes/origin/$branch" &&
		exit_name_taken "remote branch origin/$branch"
	# Also catches two branches with the same slug (feat/x, feat-x).
	if [ -e "$wt_path" ] || [ -L "$wt_path" ]; then
		exit_name_taken "worktree path $wt_path"
	fi
	# `hc run --name` must be unique among live terminals (plain `hc ls`).
	local live
	live="$(hc ls --json)" || die 4 "hc ls failed, so hc is not usable; nothing was created"
	if printf '%s\n' "$live" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' |
		sed 's/.*"\([^"]*\)"$/\1/' | grep -qxF -- "$hc_name"; then
		exit_name_taken "live hc terminal named $hc_name"
	fi
	return 0
}

# --- templates ---------------------------------------------------------------

# Exits 4 unless `hc templates` lists $1. Never installs a template.
refuse_missing_template() {
	local name="$1" listed shipped
	listed="$(hc templates --json)" || die 4 "hc templates failed, so hc is not usable; nothing was created"
	# Compared as JSON text, so names with quotes or backslashes match too.
	if printf '%s\n' "$listed" | sed 's/"name"[[:space:]]*:[[:space:]]*/"name":/g' |
		grep -qF -- "\"name\":$(json_str "$name")"; then
		return 0
	fi
	shipped="$(cd "$(dirname "$0")" && pwd -P)/templates"
	say "template not found: $name (hc templates does not list it); nothing was created"
	say "templates go in ~/.config/herdr-core/templates/$name.md; copy or link one from $shipped"
	exit 4
}

# Reads hc run's first_message record. Sets TASK_SENT (true/false),
# REASON_JSON (a JSON string or null) and REASON_TEXT (for stderr).
read_first_message() {
	local rest
	TASK_SENT="false" REASON_JSON="null" REASON_TEXT=""
	case "$1" in
	*'"first_message"'*) ;;
	*)
		REASON_TEXT="hc did not report whether the task was sent"
		REASON_JSON="$(json_str "$REASON_TEXT")"
		return 0
		;;
	esac
	# The first "sent" and "reason" keys after "first_message" are its own.
	rest="${1#*\"first_message\"}"
	case "$rest" in
	*'"sent"'*)
		if printf '%s' "${rest#*\"sent\"}" | grep -Eq '^[[:space:]]*:[[:space:]]*true'; then
			TASK_SENT="true"
			return 0
		fi
		;;
	esac
	case "$rest" in
	*'"reason"'*)
		REASON_JSON="$(printf '%s' "${rest#*\"reason\"}" |
			sed -nE '1s/^[[:space:]]*:[[:space:]]*("([^"\\]|\\.)*"|null).*/\1/p')"
		;;
	esac
	[ -n "$REASON_JSON" ] || REASON_JSON="null"
	if [ "$REASON_JSON" = "null" ]; then
		REASON_TEXT="hc gave no reason"
	else
		REASON_TEXT="${REASON_JSON#\"}"
		REASON_TEXT="${REASON_TEXT%\"}"
		REASON_TEXT="$(printf '%s' "$REASON_TEXT" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
	fi
}

# Prints the main checkout's path, so worktrees never nest in a linked one.
# In the main checkout that is its top level, wherever the git dir is
# (`git init --separate-git-dir`). From a linked worktree it is the parent
# of the common .git dir; a separate git dir keeps no record of its main
# checkout (`git worktree list` shows the git dir), so that exits 4.
# A bare repo has no main checkout: its worktrees go beside the git dir.
main_checkout() {
	local git_dir common top
	git_dir="$(git rev-parse --path-format=absolute --git-dir)" ||
		die 4 "cannot find the main checkout"
	common="$(git rev-parse --path-format=absolute --git-common-dir)" ||
		die 4 "cannot find the main checkout"
	if [ "$(git --git-dir="$common" rev-parse --is-bare-repository)" = "true" ]; then
		dirname "$common"
	elif [ "$git_dir" = "$common" ]; then
		top="$(git rev-parse --show-toplevel)" || die 4 "cannot find the main checkout"
		printf '%s\n' "$top"
	elif [ "$(basename "$common")" = ".git" ]; then
		dirname "$common"
	else
		die 4 "cannot find the main checkout: $common is a separate git dir; run it from the main checkout"
	fi
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
		printf '  ' >&2
		shell_line git worktree remove "$WT_PATH" >&2
		left=1
	fi
	if [ "$BRANCH_EXISTED" -eq 0 ] && [ -n "$BRANCH" ] &&
		git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
		[ "$left" -eq 1 ] || say "branch left behind: $BRANCH"
		printf '  ' >&2
		shell_line git branch -d "$BRANCH" >&2
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

# --- origin base -------------------------------------------------------------

origin_base_fail() {
	say "$*"
	say "nothing was created"
	exit 3
}

# Fetches $1 from origin into refs/remotes/origin/$1, the ref the new branch
# starts from. Only that remote-tracking ref is written, never a local branch.
fetch_origin_base() {
	local base="$1" rc
	git remote get-url origin >/dev/null 2>&1 || origin_base_fail "no origin remote"
	say "fetching $base from origin"
	if ! git fetch -q --no-tags origin "+refs/heads/$base:refs/remotes/origin/$base" >&2; then
		# ls-remote --exit-code exits 2 when origin answered without the branch.
		git ls-remote -q --exit-code --heads origin "refs/heads/$base" >/dev/null 2>&1
		rc=$?
		[ "$rc" -ne 2 ] || origin_base_fail "origin has no branch $base"
		origin_base_fail "git fetch origin $base failed"
	fi
	git rev-parse --verify -q "refs/remotes/origin/$base^{commit}" >/dev/null ||
		origin_base_fail "origin has no branch $base"
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

# --- shell quoting -----------------------------------------------------------

# Prints $1 quoted for a POSIX-ish shell (bash, zsh): bare when safe, in
# single quotes otherwise, and as $'...' when it holds a control char (such as
# a newline), so every command stays on one line.
shquote() {
	local s="$1" esc="'\\''"
	# First: grep checks line by line, so a newline would look safe to it.
	case "$s" in
	*[[:cntrl:]]*)
		printf '%q' "$s"
		return 0
		;;
	esac
	# grep under LC_ALL=C matches bytes, so non-ASCII is always quoted.
	if [ -n "$s" ] && ! printf '%s' "$s" | LC_ALL=C grep -q '[^A-Za-z0-9_./:=@%+,-]'; then
		printf '%s' "$s"
	else
		printf "'%s'" "${s//\'/$esc}"
	fi
}

# Prints its arguments as one shell-quoted command line.
shell_line() {
	local a sep=""
	for a in "$@"; do
		printf '%s' "$sep"
		shquote "$a"
		sep=" "
	done
	printf '\n'
}

# --- task --------------------------------------------------------------------

# Sets $task from stdin, byte-for-byte: the trailing "." sentinel keeps $(...)
# from dropping trailing newlines. A TTY or a blank task is a usage error.
read_stdin_task() {
	[ ! -t 0 ] || usage_error "stdin is a terminal; pass the task on stdin (see the heredoc example)"
	task="$(cat && printf .)" || usage_error "cannot read the task from stdin"
	task="${task%.}"
	case "$task" in
	*[![:space:]]*) ;;
	*) usage_error "empty task on stdin" ;;
	esac
}

# --- start -------------------------------------------------------------------

cmd_start() {
	local base="main" branch="" task="" arg
	local template="implementer"
	local flag value

	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
		--) usage_error "unexpected --: the task is read from stdin" ;;
		--base | --branch | --template | \
			--base=* | --branch=* | --template=*)
			# --flag=value and --flag value both end up as $flag and $value.
			case "$arg" in
			*=*)
				flag="${arg%%=*}"
				value="${arg#*=}"
				;;
			*)
				if [ "$#" -lt 2 ] || [ "$2" = "--" ]; then
					usage_error "$arg needs a value"
				fi
				flag="$arg"
				value="$2"
				shift
				;;
			esac
			case "$flag" in
			--base) base="$value" ;;
			--branch) branch="$value" ;;
			--template) template="$value" ;;
			esac
			;;
		-*) usage_error "unknown flag: $arg" ;;
		*) usage_error "unexpected argument: $arg (the task is read from stdin)" ;;
		esac
		shift
	done

	[ -n "$branch" ] || usage_error "missing --branch"
	[ -n "$base" ] || usage_error "--base needs a value"
	[ -n "$template" ] || usage_error "--template needs a value"
	read_stdin_task

	command -v git >/dev/null 2>&1 || die 4 "git not found on PATH"

	# grep under LC_ALL=C matches bytes, so non-ASCII never passes.
	if printf '%s' "$branch" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
		usage_error "invalid branch name (ASCII letters, digits and . _ / - only): $branch"
	fi
	git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
		usage_error "invalid branch name: $branch"
	git check-ref-format --branch "$base" >/dev/null 2>&1 ||
		usage_error "invalid --base branch name: $base"

	local slug hc_name
	slug="$(slugify "$branch")"
	[ -n "$slug" ] || usage_error "branch name gives an empty slug: $branch"
	hc_name="$(hc_name_for "$slug")"
	[ -n "$hc_name" ] || usage_error "branch name gives an empty hc name: $branch"

	git rev-parse --git-dir >/dev/null 2>&1 || die 4 "not inside a git repository"
	command -v hc >/dev/null 2>&1 || die 4 "hc not found on PATH"
	[ -n "${HC_TERMINAL_ID:-}" ] || die 4 "HC_TERMINAL_ID is not set (run this from a Herdr terminal)"
	refuse_missing_template "$template"

	local root
	root="$(main_checkout)" || exit 4
	local wt_path="$root/.worktrees/$slug"

	refuse_taken_names "$branch" "$wt_path" "$hc_name"

	# After the name-conflict checks; Ctrl-C leaves git as git leaves it.
	trap on_interrupt INT
	fetch_origin_base "$base"

	# Work starts here: from now on, failures may leave things behind.
	WT_PATH="$wt_path"
	BRANCH="$branch"
	if git show-ref --verify --quiet "refs/heads/$branch"; then BRANCH_EXISTED=1; else BRANCH_EXISTED=0; fi
	if [ -e "$wt_path" ]; then PATH_EXISTED=1; else PATH_EXISTED=0; fi
	trap on_interrupt INT

	say "creating worktree $wt_path on new branch $branch from origin/$base"
	git worktree add -q --no-track -b "$branch" "$wt_path" "refs/remotes/origin/$base" >&2 ||
		fail_after_start "git worktree add failed"

	# hc joins the template body and the task into the first message and adds
	# the report-back target; the script sends only the task.
	say "starting template $template as $hc_name"
	local hc_output
	hc_output="$(hc run --bg --name "$hc_name" --cwd "$wt_path" -- "$template" "$task")" ||
		fail_after_start "hc run failed"

	# Piped, hc prints JSON; take its "address". Fall back to a bare id.
	local terminal
	terminal="$(printf '%s\n' "$hc_output" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	if [ -z "$terminal" ]; then
		case "$hc_output" in
		*[!A-Za-z0-9/_-]* | "") ;;
		*) terminal="$hc_output" ;;
		esac
	fi
	[ -n "$terminal" ] || fail_after_start "could not read the terminal id from hc run: $hc_output"

	read_first_message "$hc_output"

	trap - INT
	print_json "$terminal" "$hc_name" "$branch" "$base" "$wt_path" "$template" "$TASK_SENT" "$REASON_JSON"
	if [ "$TASK_SENT" = "true" ]; then
		say "started Herdr subagent $terminal ($hc_name)"
		return 0
	fi
	say "task not sent to $terminal ($hc_name): $REASON_TEXT; the terminal and worktree are kept"
	exit 6
}

# Prints the one JSON line on stdout. $7 is true/false, $8 already JSON.
print_json() {
	local terminal="$1" name="$2" branch="$3" base="$4" wt_path="$5"
	local template="$6" task_sent="$7" reason_json="$8"
	printf '{"terminal":%s,"name":%s,"branch":%s,"base":%s,"worktree":%s,"template":%s,"task_sent":%s,"reason":%s}\n' \
		"$(json_str "$terminal")" "$(json_str "$name")" "$(json_str "$branch")" \
		"$(json_str "$base")" "$(json_str "$wt_path")" "$(json_str "$template")" \
		"$task_sent" "$reason_json"
}

# --- main --------------------------------------------------------------------

main() {
	local arg seen_start=0
	# -h/--help wins over everything.
	for arg in "$@"; do
		case "$arg" in
		start) seen_start=1 ;;
		-h | --help)
			if [ "$seen_start" -eq 1 ]; then print_start_help; else print_main_help; fi
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
		2:start) print_start_help ;;
		*) usage_error "unknown help topic: ${2:-}" ;;
		esac
		;;
	start)
		shift
		cmd_start "$@"
		;;
	-*) usage_error "unknown flag: $1" ;;
	*) usage_error "unknown subcommand: $1" ;;
	esac
}

main "$@"
