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

# The one place for guidance: every help topic prints all of it.
print_help() {
	cat <<HELP
$PROG - start and close Herdr subagents, each in its own worktree

Examples:
  $PROG start --branch fix/docs <<'EOF'
  Fix the "quoted" \$HOME and \`backtick\` bits in the docs (issue #48).
  Push the branch and open a PR against main.
  EOF
  hc wait --children any
  $PROG close fix/docs
  $PROG start --branch fix/48 --issue 48 --label batch=b1 <task.md

Usage:
  $PROG start [flags] <<'EOF'
  <task>
  EOF
  $PROG close <branch>
  $PROG help [start|close]
  $PROG --version

Commands:
  start  Create a worktree on a new branch from origin/<base> and start an
         hc template in it; the task is read from stdin
  close  Kill a Herdr subagent's terminal, remove its worktree, and delete
         its branch once it is merged into origin/<base>
  help   Show this help (every topic shows all of it)

start flags:
  --branch <name>   New branch for the worktree (required).
                    ASCII letters, digits and . _ / - only.
  --base <branch>   Base branch: a branch on origin to start from
                    (default: main).
  --template <name> hc template to launch from (default: implementer).
  --parent <t>      Live hc terminal that gets the reports
                    (default: \$HC_TERMINAL_ID).
  --issue <n>       Issue number (digits only), as label subagent.issue.
  --label <k=v>     Extra label, repeatable. Keys use ASCII letters,
                    digits and . _ -; subagent.*, herdr.* and where are
                    reserved.

close takes one branch and no flags.

Global flags:
  -h, --help        Show this help; wins over every other argument.
  --version         Print the version.

Flags take \`--flag value\` or \`--flag=value\`, in any order.

Task: read from stdin, byte-for-byte, trailing newlines included. Use a
quoted heredoc (<<'EOF') so quotes, \$ and backticks reach the Herdr
subagent unchanged. An empty or whitespace-only task, or stdin attached
to a terminal, exits 2.

Worktree: start fetches <base> from origin and creates the new branch
from origin/<base>; no local branch is ever written. The worktree goes to
<main-checkout-root>/.worktrees/<slug(branch)>, even when you run it from
another worktree. The hc name is derived from the branch.

Templates: the Herdr subagent is started from an hc template and the task.
The template sets the Harness, model, effort, permissions and the child's
fixed rules; hc adds the report-back target, so the script sends only the
task. It must be listed by \`hc templates\`: a Markdown file in
~/.config/herdr-core/templates/<name>.md. This repo ships
scripts/herdr-subagent/templates/implementer.md and implementer-codex.md;
copy or link them there:
  implementer        Claude Code, with \`hc send\` and \`hc label\` pre-allowed.
  implementer-codex  Codex in its workspace-write sandbox with network
                     access on: hc cannot reach its core from inside that
                     sandbox otherwise, and the child needs \`hc send\` and
                     \`hc label\`.
The script never installs a template; a different setup is a different
template.

Parent: the Herdr subagent reports to --parent, else \$HC_TERMINAL_ID. It
must be a live hc terminal: run it from an hc terminal, under
\`hc run --bg\`, or pass --parent <t>.

Labels: every Herdr subagent gets subagent.repo (the main checkout root),
subagent.branch and subagent.base, plus subagent.issue and your --label
ones. The shipped templates have the child set subagent.pr=<PR URL> when
it opens a PR.

close: finds the terminal by its subagent.repo and subagent.branch labels
(a finished one too), kills it, then removes the worktree. A worktree
with uncommitted or untracked changes exits 3 and touches nothing. close
fetches the base (the terminal's subagent.base label, else main) and
deletes the local branch only when its tip is an ancestor of
origin/<base>, as a merge commit leaves it. Otherwise the branch is kept
and the JSON says why; a failed fetch keeps it too. The terminal's hc
record is removed last, so a rerun still knows the base. There is no
--force. Rerun close after a partial failure to finish, even when only
the local branch is left. The branch checked out in the main checkout is
refused (exit 2).

stdout is always one JSON line. start prints:
  {"terminal","name","branch","base","worktree","template","issue",
   "labels","task_sent","reason"}
issue is a number or null; labels holds every label applied. reason is
hc's reason when task_sent is false, null otherwise. close prints:
  {"branch","worktree","terminal_killed","worktree_removed",
   "branch_deleted","branch_kept_reason"}
worktree is null when none was found. terminal_killed is also true when a
finished terminal was only removed. branch_kept_reason is null once the
branch is deleted, else one of:
  not merged into origin/<base>; pushed to origin/<branch>
  not merged into origin/<base>; not pushed (its tip is not on origin)
  could not check the merge: <fetch error>
  no local branch <branch>
stderr carries only progress, errors, leftovers after a failure and one
final "started" or "closed" line.

Exit codes:
       start                               close
  0    started, task sent                  closed (the branch may be kept)
  1    git or hc failed after work         git or hc failed midway; close
       started; leftovers are printed      again to finish
  2    usage error, including a bad        usage error, including the
       label or a TTY or empty stdin       main checkout's branch
  3    no origin, a failed fetch, or       dirty worktree; nothing touched
       <base> missing on origin
  4    missing git repo, hc, template      missing git repo or hc
       or live parent
  5    branch, worktree path or live hc    no worktree, no labelled
       name already exists                 terminal and no local branch
  6    started, but hc did not deliver     -
       the task (task_sent false)
  130  interrupted                         interrupted
After start exits 2 to 5, nothing was created.

Tips for agents:
  - Pass the task with a quoted heredoc (<<'EOF') and put everything this
    launch needs in it: the issue, the files, how to verify, where to open
    the PR. The template already holds the fixed rules.
  - Wait with \`hc wait --children any\` instead of polling or sleeping; it
    returns on a child's next report, block, error or exit.
  - Treat a report as claims: check the worktree (git log, git diff, the
    tests) before you rely on it.
  - Exit 6: the child is up but idle, often on a trust dialog. Read its
    screen (\`hc read <t>\`), resolve it (\`hc keys <t> enter\`), then send
    the task yourself (\`hc send <t> "\$(cat task.md)"\`).
  - On a permission prompt (hc wait says the child is blocked), read its
    screen and answer it with \`hc keys\`, or allow the command in the
    template so it does not ask again.
  - Exit 5: the name is taken; pick another --branch and retry. An existing
    branch is never reused.
  - List your Herdr subagents with \`hc ls --label subagent.repo=<root>\`, or
    \`--label subagent.issue=<n>\`; add \`--all\` for finished ones.
  - Close only merged work: close keeps an unmerged branch, so merge the PR
    first, or delete the branch yourself if you mean to discard it.
  - If .worktrees/ shows up in git status, ignore it in that repo
    (.gitignore or .git/info/exclude); the script never edits either.

Report issues: $ISSUES_URL
HELP
}

print_short_help() {
	cat <<HELP
Usage: $PROG start [flags] <<'EOF'
<task>
EOF
       $PROG close <branch>

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

# --- parent ------------------------------------------------------------------

# shellcheck disable=SC2016 # backticks quote commands, not substitutions
PARENT_HINT='run it from an hc terminal, under `hc run --bg`, or pass `--parent <t>`'

# Exits 4 unless $1 is a live hc terminal, so a child is never orphaned.
refuse_dead_parent() {
	local parent="$1" got
	[ -n "$parent" ] || die 4 "no parent: $PARENT_HINT; nothing was created"
	got="$(hc get "$parent" --json 2>/dev/null)" ||
		die 4 "parent $parent is not a live hc terminal: $PARENT_HINT; nothing was created"
	printf '%s\n' "$got" | grep -q '"state"[[:space:]]*:[[:space:]]*"live"' ||
		die 4 "parent $parent is not a live hc terminal: $PARENT_HINT; nothing was created"
}

# --- labels ------------------------------------------------------------------

# Set by add_label: the hc run flags, the JSON object body, the keys seen.
LABEL_ARGS=()
LABELS_JSON=""
LABEL_KEYS=" "

add_label() {
	local key="$1" value="$2"
	LABEL_ARGS[${#LABEL_ARGS[@]}]="--label"
	LABEL_ARGS[${#LABEL_ARGS[@]}]="$key=$value"
	[ -z "$LABELS_JSON" ] || LABELS_JSON="$LABELS_JSON,"
	LABELS_JSON="$LABELS_JSON$(json_str "$key"):$(json_str "$value")"
	LABEL_KEYS="$LABEL_KEYS$key "
}

# Exits 2 unless $1 is k=v with a free key: ASCII letters, digits and . _ -
# (starting with a letter or digit), and a non-empty value without control
# chars. Keys under subagent., herdr. and where belong to the script and the app.
check_user_label() {
	local label="$1" key value
	case "$label" in
	*=*) ;;
	*) usage_error "invalid --label (want k=v): $label" ;;
	esac
	key="${label%%=*}"
	value="${label#*=}"
	if [ -z "$key" ] || [ -z "$value" ] ||
		printf '%s' "$key" | LC_ALL=C grep -q '[^A-Za-z0-9._-]' ||
		! printf '%s' "$key" | LC_ALL=C grep -q '^[A-Za-z0-9]'; then
		usage_error "invalid --label (want k=v; keys use ASCII letters, digits and . _ -): $label"
	fi
	case "$value" in
	*[[:cntrl:]]*) usage_error "invalid --label (control character in the value): $key" ;;
	esac
	case "$key" in
	subagent.* | herdr.* | where | where.*)
		usage_error "reserved --label key (subagent.*, herdr.* and where are taken): $key"
		;;
	esac
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
	try_fetch_origin_base "$1" || origin_base_fail "$FETCH_ERROR"
}

# Like fetch_origin_base, but returns 1 with the cause in FETCH_ERROR.
FETCH_ERROR=""
try_fetch_origin_base() {
	local base="$1" rc
	FETCH_ERROR=""
	if ! git remote get-url origin >/dev/null 2>&1; then
		FETCH_ERROR="no origin remote"
		return 1
	fi
	say "fetching $base from origin"
	if ! git fetch -q --no-tags origin "+refs/heads/$base:refs/remotes/origin/$base" >&2; then
		# ls-remote --exit-code exits 2 when origin answered without the branch.
		git ls-remote -q --exit-code --heads origin "refs/heads/$base" >/dev/null 2>&1
		rc=$?
		if [ "$rc" -eq 2 ]; then
			FETCH_ERROR="origin has no branch $base"
		else
			FETCH_ERROR="git fetch origin $base failed"
		fi
		return 1
	fi
	if ! git rev-parse --verify -q "refs/remotes/origin/$base^{commit}" >/dev/null; then
		FETCH_ERROR="origin has no branch $base"
		return 1
	fi
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
	local template="implementer" parent="${HC_TERMINAL_ID:-}" issue=""
	local flag value user_labels=() label key seen=" "

	while [ "$#" -gt 0 ]; do
		arg="$1"
		case "$arg" in
		--) usage_error "unexpected --: the task is read from stdin" ;;
		--base | --branch | --template | --parent | --issue | --label | \
			--base=* | --branch=* | --template=* | --parent=* | --issue=* | --label=*)
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
			--parent)
				[ -n "$value" ] || usage_error "--parent needs a value"
				parent="$value"
				;;
			--issue)
				case "$value" in
				"" | *[!0-9]*) usage_error "--issue takes an issue number (digits only): $value" ;;
				esac
				# No leading zeros, so it is also a valid JSON number.
				issue="$(printf '%s' "$value" | sed 's/^0*//')"
				[ -n "$issue" ] || usage_error "--issue takes an issue number (digits only): $value"
				;;
			--label)
				check_user_label "$value"
				key="${value%%=*}"
				case "$seen" in
				*" $key "*) usage_error "--label $key given twice" ;;
				esac
				seen="$seen$key "
				user_labels[${#user_labels[@]}]="$value"
				;;
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
	refuse_dead_parent "$parent"
	refuse_missing_template "$template"

	local root
	root="$(main_checkout)" || exit 4
	local wt_path="$root/.worktrees/$slug"

	refuse_taken_names "$branch" "$wt_path" "$hc_name"

	# The parent, template and cwd are hc's own terminal fields: not labels.
	add_label subagent.repo "$root"
	add_label subagent.branch "$branch"
	add_label subagent.base "$base"
	[ -z "$issue" ] || add_label subagent.issue "$issue"
	# ${a[@]+...}: bash 3.2 calls an empty array unset under set -u.
	for label in ${user_labels[@]+"${user_labels[@]}"}; do
		add_label "${label%%=*}" "${label#*=}"
	done

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
	hc_output="$(hc run --bg --name "$hc_name" --cwd "$wt_path" --parent "$parent" "${LABEL_ARGS[@]}" -- "$template" "$task")" ||
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
	print_json "$terminal" "$hc_name" "$branch" "$base" "$wt_path" "$template" "$issue" "$TASK_SENT" "$REASON_JSON"
	if [ "$TASK_SENT" = "true" ]; then
		say "started Herdr subagent $terminal ($hc_name)"
		return 0
	fi
	say "task not sent to $terminal ($hc_name): $REASON_TEXT; the terminal and worktree are kept"
	exit 6
}

# Prints the one JSON line on stdout. $7 is the issue number or empty,
# $8 true/false, $9 already JSON; the labels come from LABELS_JSON.
print_json() {
	local terminal="$1" name="$2" branch="$3" base="$4" wt_path="$5"
	local template="$6" issue="${7:-null}" task_sent="$8" reason_json="$9"
	printf '{"terminal":%s,"name":%s,"branch":%s,"base":%s,"worktree":%s,"template":%s,"issue":%s,"labels":{%s},"task_sent":%s,"reason":%s}\n' \
		"$(json_str "$terminal")" "$(json_str "$name")" "$(json_str "$branch")" \
		"$(json_str "$base")" "$(json_str "$wt_path")" "$(json_str "$template")" \
		"$issue" "$LABELS_JSON" "$task_sent" "$reason_json"
}

# --- close -------------------------------------------------------------------

# Prints the path of the worktree that has $1 checked out, if any.
worktree_of_branch() {
	git worktree list --porcelain | awk -v want="branch refs/heads/$1" '
		/^worktree / { wt = substr($0, 10) }
		$0 == want { print wt; exit }'
}

# Prints the subagent.base label in the hc terminal JSON $1, if it has one.
base_label() {
	printf '%s\n' "$1" |
		sed -n 's/.*"subagent\.base"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1
}

# Deletes branch $1 once merged into a freshly fetched origin/$2: its tip is
# an ancestor of origin/$2 (PRs merge with merge commits). Otherwise sets
# KEPT to why it stays; KEPT is empty once the branch is deleted.
KEPT=""
delete_branch_if_merged() {
	local branch="$1" base="$2" tip
	KEPT=""
	if ! tip="$(git rev-parse -q --verify "refs/heads/$branch^{commit}")"; then
		KEPT="no local branch $branch"
		return 0
	fi
	# A stale origin/<base> could say merged when it is not: no fetch, no delete.
	if ! try_fetch_origin_base "$base"; then
		KEPT="could not check the merge: $FETCH_ERROR"
	elif git merge-base --is-ancestor "$tip" "refs/remotes/origin/$base"; then
		say "deleting branch $branch (merged into origin/$base)"
		git branch -q -D "$branch" >&2 || die 1 "git branch -D $branch failed; close again to finish"
		return 0
	elif [ "$(git ls-remote -q origin "refs/heads/$branch" 2>/dev/null | cut -f1)" = "$tip" ]; then
		KEPT="not merged into origin/$base; pushed to origin/$branch"
	else
		KEPT="not merged into origin/$base; not pushed (its tip is not on origin)"
	fi
	say "keeping branch $branch: $KEPT"
}

cmd_close() {
	local branch="" arg
	for arg in "$@"; do
		case "$arg" in
		-*) usage_error "unknown flag: $arg (close has no flags)" ;;
		esac
		[ -z "$branch" ] || usage_error "unexpected argument: $arg (close takes one branch)"
		branch="$arg"
	done
	[ -n "$branch" ] || usage_error "missing branch: close <branch>"

	command -v git >/dev/null 2>&1 || die 4 "git not found on PATH"
	git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
		usage_error "invalid branch name: $branch"
	git rev-parse --git-dir >/dev/null 2>&1 || die 4 "not inside a git repository"
	command -v hc >/dev/null 2>&1 || die 4 "hc not found on PATH"

	# Everything is looked up before anything is touched.
	local root wt_path
	root="$(main_checkout)" || exit 4
	wt_path="$(worktree_of_branch "$branch")"
	[ "$wt_path" != "$root" ] ||
		usage_error "$branch is checked out in the main checkout; close only cleans up a Herdr subagent's worktree"

	# Finished terminals too: a Herdr subagent ends with its parent.
	local listed terminals t got base=""
	listed="$(hc ls --all --json --label "subagent.repo=$root" --label "subagent.branch=$branch")" ||
		die 4 "hc ls failed, so hc is not usable; nothing was touched"
	terminals="$(printf '%s\n' "$listed" | grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' |
		sed 's/.*"\([^"]*\)"$/\1/')"
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		got="$(hc get "$t" --json)" || die 4 "hc get $t failed; nothing was touched"
		[ -n "$base" ] || base="$(base_label "$got")"
	done <<EOF
$terminals
EOF
	# With no terminal record left, the base falls back to main.
	[ -n "$base" ] || base="main"

	# A local branch alone is still work to finish: a rerun after a failed
	# delete finds no worktree and maybe no terminal.
	if [ -z "$wt_path" ] && [ -z "$terminals" ] &&
		! git show-ref --verify --quiet "refs/heads/$branch"; then
		say "no worktree, no labelled hc terminal and no local branch $branch"
		exit 5
	fi

	if [ -n "$wt_path" ] && [ -d "$wt_path" ] &&
		[ -n "$(git -C "$wt_path" status --porcelain --untracked-files=all)" ]; then
		say "worktree $wt_path has uncommitted or untracked changes; nothing was touched"
		exit 3
	fi

	local term_removed=false removed=false deleted=false kept_json=null wt_json=null
	# Kill first and hc rm last: until the end, the terminal record keeps the
	# subagent.base label a rerun needs.
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		say "killing terminal $t"
		# hc kill waits for the program to end, and succeeds once it has.
		hc kill "$t" --json >/dev/null || die 1 "hc kill $t failed; close again to finish"
	done <<EOF
$terminals
EOF

	if [ -n "$wt_path" ]; then
		say "removing worktree $wt_path"
		if [ -d "$wt_path" ]; then
			git worktree remove "$wt_path" >&2 ||
				die 1 "git worktree remove $wt_path failed; close again to finish"
		else
			git worktree prune >&2 || die 1 "git worktree prune failed; close again to finish"
		fi
		removed=true
		wt_json="$(json_str "$wt_path")"
	fi

	delete_branch_if_merged "$branch" "$base"
	if [ -z "$KEPT" ]; then
		deleted=true
	else
		kept_json="$(json_str "$KEPT")"
	fi

	while IFS= read -r t; do
		[ -n "$t" ] || continue
		say "removing terminal $t"
		hc rm "$t" --json >/dev/null || die 1 "hc rm $t failed; close again to finish"
		term_removed=true
	done <<EOF
$terminals
EOF

	printf '{"branch":%s,"worktree":%s,"terminal_killed":%s,"worktree_removed":%s,"branch_deleted":%s,"branch_kept_reason":%s}\n' \
		"$(json_str "$branch")" "$wt_json" "$term_removed" "$removed" "$deleted" "$kept_json"
	say "closed $branch"
}

# --- main --------------------------------------------------------------------

main() {
	local arg
	# -h/--help wins over everything.
	for arg in "$@"; do
		case "$arg" in
		-h | --help)
			print_help
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
		1: | 2:start | 2:close) print_help ;;
		*) usage_error "unknown help topic: ${2:-}" ;;
		esac
		;;
	start)
		shift
		cmd_start "$@"
		;;
	close)
		shift
		cmd_close "$@"
		;;
	-*) usage_error "unknown flag: $1" ;;
	*) usage_error "unknown subcommand: $1" ;;
	esac
}

main "$@"
