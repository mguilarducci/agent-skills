#!/usr/bin/env bash
# herdr-subagent: launch a Herdr subagent (Claude Code or Codex) in its own worktree.
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
$PROG - launch a Herdr subagent in its own worktree

Examples:
  t=\$($PROG run --branch feat/login -- "Add OAuth login")
  $PROG run --base develop --branch fix/parser -- "Fix the v1.2 parser"
  hc wait "\$t"

Usage:
  $PROG run [flags] -- "<task>"
  $PROG help [run]
  $PROG --version

Commands:
  run    Create a worktree on a new branch and start the Harness in it through hc
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
$PROG run - start a Herdr subagent in a new worktree

Examples:
  t=\$($PROG run --branch feat/login -- "Add OAuth login")
  $PROG run --base develop --branch fix/parser -- "Fix the v1.2 parser"
  $PROG run --branch=issue-6 -- "Implement issue #6"
  $PROG run --harness codex --effort high --branch fix/ci -- "Fix CI"
  $PROG run --dry-run --json --branch fix/ci -- "Fix CI"
  $PROG run --branch fix/docs --task-file - <<'EOF'
  Fix the "quoted" \$HOME and \`backtick\` bits in the docs.
  EOF

Usage:
  $PROG run [flags] -- "<task>"
  $PROG run [flags] --task-file <path|->

Flags:
  --branch <name>   New branch for the worktree (required).
                    ASCII letters, digits and . _ / - only.
  --base <branch>   Base branch: an existing local branch to start from
                    (default: main).
  --harness <claude|codex>
                    Harness: the agent program to start (default: claude).
  --model <s>       Passed as-is: claude --model <s>, codex -m <s>.
  --effort <s>      Passed as-is: claude --effort <s>,
                    codex -c model_reasoning_effort=<s>.
                    Left out, the harness's own config applies.
  --no-base-update  Skip the Base update (see below).
  --task-file <path|->
                    Read the task from a file, or from stdin with -,
                    instead of after --. The task is passed byte-for-byte,
                    trailing newlines included; an empty or
                    whitespace-only task exits 2.
  --json            Print one JSON object on stdout instead of the id:
                    {"terminal","name","branch","base","worktree",
                    "harness","model"}; model is null without --model.
  -n, --dry-run     Run nothing that changes state (not even git fetch);
                    print the plan on stdout, one shell-quoted command per
                    line, and exit 0. Arguments, prerequisites and names
                    are still checked (exits 2, 4, 5). With --json, the
                    object has "terminal":null and "commands":[...].
  -h, --help        Show this help.

Flags take \`--flag value\` or \`--flag=value\`, in any order before \`--\`.

The worktree goes to <main-checkout-root>/.worktrees/<slug(branch)>.
stdout carries only the Herdr subagent's terminal id (or the --json
object); progress, errors and the summary go to stderr.

Base update: before creating the worktree, run fetches origin and brings
the Base branch up to date with origin/main, in the worktree that has it
checked out. main is fast-forwarded; any other Base branch gets origin/main
merged in. A main that is not checked out anywhere is fast-forwarded as a
ref. It never auto-resolves: these abort with exit 3 and leave git as it
was, even when the Base branch already has origin/main: uncommitted or
untracked changes where the Base branch is checked out, or a Base branch
other than main checked out nowhere. So do a diverged main, a conflicting
merge, a failed fetch or no origin.

In a dry run the Base update lines come from local state only: they show
the step run takes if the fetch brings new commits to origin/main (run
skips it if not). Known causes of an exit-3 abort are noted on stderr.

Exit codes:
  0    launched
  1    git or hc failed after work started (leftovers are printed)
  2    usage error; nothing was created
  3    the Base update could not complete cleanly; nothing was created
  4    missing git repo, hc (or a failing hc ls), the chosen Harness or
       \$HC_TERMINAL_ID; nothing was created
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

# --- base update -------------------------------------------------------------

# Abort the Base update: nothing was changed and nothing will be created.
base_update_abort() {
	say "Base update failed: $*"
	say "nothing was created; fix it and rerun, or skip it with --no-base-update"
	exit 3
}

# git merge flags for the Base update, shared by run and the dry run. They
# override branch.<base>.mergeOptions and merge.* config (such as --no-commit
# or --squash) that would leave the merge uncommitted.
BASE_MERGE_FF=(-q --ff-only --no-squash --commit)
BASE_MERGE=(-q --no-edit --no-squash --commit)

# Path of the worktree that has refs/heads/$1 checked out, if any.
worktree_with_branch() {
	git worktree list --porcelain | awk -v ref="refs/heads/$1" '
		/^worktree / { wt = substr($0, 10) }
		$0 == "branch " ref { print wt; exit }
	'
}

# Decides the Base update step from local state only, shared by run and the
# dry run so they cannot drift apart. Sets BASE_STEP to one of:
#   ff-worktree  fast-forward main in BASE_WT, where it is checked out
#   ff-ref       fast-forward the main ref (checked out nowhere)
#   merge        merge origin/main into the Base branch in BASE_WT
#   abort        BASE_ABORT says why; run exits 3
# The abort cases hold even when the Base branch already has origin/main.
base_update_step() {
	local base="$1"
	BASE_ABORT=""
	BASE_WT="$(worktree_with_branch "$base")"
	if ! git remote get-url origin >/dev/null 2>&1; then
		BASE_STEP="abort" BASE_ABORT="no origin remote"
	# .worktrees/ holds earlier Herdr subagents' worktrees; it is not dirt.
	elif [ -n "$BASE_WT" ] && [ -n "$(git -C "$BASE_WT" status --porcelain --untracked-files=normal -- ':(top,exclude).worktrees')" ]; then
		BASE_STEP="abort" BASE_ABORT="$BASE_WT (where $base is checked out) has uncommitted or untracked changes"
	elif [ "$base" = "main" ]; then
		if [ -n "$BASE_WT" ]; then BASE_STEP="ff-worktree"; else BASE_STEP="ff-ref"; fi
	elif [ -n "$BASE_WT" ]; then
		BASE_STEP="merge"
	else
		BASE_STEP="abort" BASE_ABORT="$base is not checked out in any worktree, so origin/main cannot be merged into it"
	fi
}

# Bring the Base branch up to date with origin/main. Main is fast-forwarded;
# any other Base branch gets origin/main merged in. Never auto-resolves:
# anything that is not clean aborts with exit 3 and leaves git as it was.
base_update() {
	local base="$1"
	base_update_step "$base"
	[ "$BASE_STEP" != "abort" ] || base_update_abort "$BASE_ABORT"
	say "Base update: fetching origin"
	git fetch -q origin >&2 || base_update_abort "git fetch origin failed"
	git rev-parse --verify -q refs/remotes/origin/main >/dev/null ||
		base_update_abort "origin has no main branch"

	if git merge-base --is-ancestor origin/main "refs/heads/$base"; then
		say "Base update: $base already has origin/main"
		return 0
	fi

	case "$BASE_STEP" in
	ff-worktree | ff-ref)
		git merge-base --is-ancestor refs/heads/main origin/main ||
			base_update_abort "main has diverged from origin/main (not a fast-forward)"
		say "Base update: fast-forwarding main to origin/main"
		if [ "$BASE_STEP" = "ff-worktree" ]; then
			git -C "$BASE_WT" merge "${BASE_MERGE_FF[@]}" origin/main >&2 ||
				base_update_abort "git merge --ff-only origin/main failed in $BASE_WT"
		else
			git update-ref -m "$PROG: Base update" refs/heads/main \
				"$(git rev-parse origin/main)" "$(git rev-parse refs/heads/main)" ||
				base_update_abort "could not fast-forward main"
		fi
		;;
	merge)
		git merge-tree --write-tree "refs/heads/$base" origin/main >/dev/null 2>&1 ||
			base_update_abort "merging origin/main into $base would conflict"
		say "Base update: merging origin/main into $base in $BASE_WT"
		if ! git -C "$BASE_WT" merge "${BASE_MERGE[@]}" origin/main >&2; then
			git -C "$BASE_WT" merge --abort >/dev/null 2>&1
			base_update_abort "git merge origin/main failed in $BASE_WT"
		fi
		;;
	esac

	# Config the flags above do not override could still leave the merge
	# uncommitted: never start the agent from a Base without origin/main.
	if ! git merge-base --is-ancestor origin/main "refs/heads/$base"; then
		if [ -n "$BASE_WT" ]; then
			# The worktree was clean before, so this only undoes the merge.
			git -C "$BASE_WT" merge --abort >/dev/null 2>&1 ||
				git -C "$BASE_WT" reset -q --merge >/dev/null 2>&1
		fi
		base_update_abort "$base does not contain origin/main after the update"
	fi
}

# The Base update as shell lines, for --dry-run. Reads only local state:
# whether origin/main has new commits is unknown without the fetch, so the
# plan shows the step run would take if it does (if not, run skips it).
# An abort that is already known is noted on stderr; a diverged main or a
# conflicting merge is only knowable after the fetch.
base_update_plan() {
	local base="$1"
	base_update_step "$base"
	[ "$BASE_STEP" != "abort" ] ||
		say "dry run: $BASE_ABORT; run would abort the Base update (exit 3)"
	shell_line git fetch -q origin
	case "$BASE_STEP" in
	ff-worktree) shell_line git -C "$BASE_WT" merge "${BASE_MERGE_FF[@]}" origin/main ;;
	ff-ref)
		# One line, guarded as in run: only a fast-forward moves main, and the
		# old value is main as it is now.
		printf '%s && %s\n' \
			"$(shell_line git merge-base --is-ancestor refs/heads/main refs/remotes/origin/main)" \
			"$(shell_line git update-ref -m "$PROG: Base update" refs/heads/main \
				refs/remotes/origin/main "$(git rev-parse refs/heads/main)")"
		;;
	merge) shell_line git -C "$BASE_WT" merge "${BASE_MERGE[@]}" origin/main ;;
	esac
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

# --- dry run -----------------------------------------------------------------

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

# --- task file -------------------------------------------------------------

# Sets $task from a file, or from stdin for "-", byte-for-byte: the trailing
# "." sentinel keeps $(...) from dropping trailing newlines.
read_task_file() {
	local f="$1"
	if [ "$f" != "-" ]; then
		[ -f "$f" ] && [ -r "$f" ] || usage_error "cannot read --task-file: $f"
	fi
	task="$(cat -- "$f" && printf .)" || usage_error "cannot read --task-file: $f"
	task="${task%.}"
	case "$task" in
	*[![:space:]]*) ;;
	*) usage_error "empty task in --task-file: $f" ;;
	esac
}

# --- run ---------------------------------------------------------------------

cmd_run() {
	local base="main" branch="" task="" have_task=0 update_base=1 arg
	local harness="claude" model="" effort="" have_model=0 have_effort=0
	local task_file="" have_task_file=0 json=0 dry_run=0
	local flag value

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
		--no-base-update) update_base=0 ;;
		--json) json=1 ;;
		-n | --dry-run) dry_run=1 ;;
		--base | --branch | --harness | --model | --effort | --task-file | \
			--base=* | --branch=* | --harness=* | --model=* | --effort=* | --task-file=*)
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
			--harness) harness="$value" ;;
			--task-file)
				task_file="$value"
				have_task_file=1
				;;
			--model)
				model="$value"
				have_model=1
				;;
			--effort)
				effort="$value"
				have_effort=1
				;;
			esac
			;;
		-*) usage_error "unknown flag: $arg" ;;
		*) usage_error "unexpected argument: $arg (put the task after --)" ;;
		esac
		shift
	done

	if [ "$have_task_file" -eq 1 ]; then
		[ "$have_task" -eq 0 ] || usage_error "give the task either after -- or with --task-file, not both"
		read_task_file "$task_file"
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

	local root
	root="$(main_checkout)" || exit 4
	local wt_path="$root/.worktrees/$slug"

	refuse_taken_names "$branch" "$wt_path" "$hc_name"
	warn_if_worktrees_not_ignored "$root"

	local prompt
	prompt="$(printf '%s\n\n%s\n%s\n%s' "$task" \
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

	if [ "$dry_run" -eq 1 ]; then
		local plan
		plan="$(
			[ "$update_base" -eq 0 ] || base_update_plan "$base"
			shell_line git worktree add -b "$branch" "$wt_path" "refs/heads/$base"
			shell_line hc run --bg --name "$hc_name" --cwd "$wt_path" "${cmd[@]}" -- "$prompt"
		)"
		if [ "$json" -eq 1 ]; then
			print_json null "$hc_name" "$branch" "$base" "$wt_path" "$harness" "$have_model" "$model" "$plan"
		else
			printf '%s\n' "$plan"
		fi
		print_summary "<terminal>" "$hc_name" "$wt_path" "$branch" "$base" "$root" "$harness" 1
		exit 0
	fi

	# After the name-conflict checks; Ctrl-C leaves git as git leaves it.
	if [ "$update_base" -eq 1 ]; then
		trap on_interrupt INT
		base_update "$base"
	fi

	# Work starts here: from now on, failures may leave things behind.
	WT_PATH="$wt_path"
	BRANCH="$branch"
	if git show-ref --verify --quiet "refs/heads/$branch"; then BRANCH_EXISTED=1; else BRANCH_EXISTED=0; fi
	if [ -e "$wt_path" ]; then PATH_EXISTED=1; else PATH_EXISTED=0; fi
	trap on_interrupt INT

	say "creating worktree $wt_path on new branch $branch from $base"
	git worktree add -b "$branch" "$wt_path" "refs/heads/$base" >&2 ||
		fail_after_start "git worktree add failed"

	say "starting $harness as $hc_name"
	local hc_output
	hc_output="$(hc run --bg --name "$hc_name" --cwd "$wt_path" "${cmd[@]}" -- "$prompt")" ||
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

	trap - INT
	if [ "$json" -eq 1 ]; then
		print_json "$(json_str "$terminal")" "$hc_name" "$branch" "$base" "$wt_path" "$harness" "$have_model" "$model"
	else
		printf '%s\n' "$terminal"
	fi
	print_summary "$terminal" "$hc_name" "$wt_path" "$branch" "$base" "$root" "$harness" 0
}

# Prints the --json object. $1 is the terminal as JSON (a string or null);
# a 9th argument, the dry-run plan (one command per line), adds "commands".
print_json() {
	local terminal_json="$1" name="$2" branch="$3" base="$4" wt_path="$5"
	local harness="$6" have_model="$7" model="$8" model_json="null" commands=""
	[ "$have_model" -eq 0 ] || model_json="$(json_str "$model")"
	if [ "$#" -ge 9 ]; then
		local line sep=""
		commands=',"commands":['
		while IFS= read -r line; do
			commands="$commands$sep$(json_str "$line")"
			sep=","
		done <<EOF
$9
EOF
		commands="$commands]"
	fi
	printf '{"terminal":%s,"name":%s,"branch":%s,"base":%s,"worktree":%s,"harness":%s,"model":%s%s}\n' \
		"$terminal_json" "$(json_str "$name")" "$(json_str "$branch")" \
		"$(json_str "$base")" "$(json_str "$wt_path")" "$(json_str "$harness")" "$model_json" "$commands"
}

print_summary() {
	local terminal="$1" name="$2" wt_path="$3" branch="$4" base="$5" root="$6" harness="$7" dry_run="$8"
	{
		printf '\n'
		if [ "$dry_run" -eq 1 ]; then
			say "dry run: nothing was run; the commands above would start Herdr subagent $name"
		else
			say "started Herdr subagent $terminal ($name)"
		fi
		printf '  worktree: %s\n' "$wt_path"
		printf '  branch:   %s (new, from %s)\n' "$branch" "$base"
		if [ "$dry_run" -eq 1 ]; then
			# No terminal exists yet, so there is nothing to read, send to or kill.
			printf '\nNext: run the same command without --dry-run to start it.\n'
		else
			printf '\nNext:\n'
			printf '  hc read %s\n' "$terminal"
			printf '  hc send %s "<message>"\n' "$terminal"
			printf '  hc wait %s\n' "$terminal"
			printf '  hc kill %s\n' "$terminal"
		fi
		printf '\n'
	} >&2
	if [ "$harness" = "codex" ]; then
		print_codex_warning "$terminal" "$dry_run" >&2
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
	# A dry run has no terminal to attach to; the real run prints these lines.
	[ "$2" -eq 0 ] || return 0
	printf '%s\n' 'If Codex shows a trust dialog, open it with:'
	printf '  hc attach %s\n' "$1"
}

print_claude_warning() {
	local root="$1"
	# Printed literally for the reader, not expanded.
	# shellcheck disable=SC2088
	local user="~/.claude/settings.json"
	local proj="$root/.claude/settings.json"
	local local_settings="$root/.claude/settings.local.json"
	local w=${#user}
	[ "${#proj}" -le "$w" ] || w=${#proj}
	[ "${#local_settings}" -le "$w" ] || w=${#local_settings}

	{
		# shellcheck disable=SC2016 # literal backticks
		printf '%s\n' 'Claude may ask before each `hc send`. To allow it for good, add "Bash(hc send:*)" to permissions.allow in one of:'
		printf '  %-*s   (user: every project)\n' "$w" "$user"
		printf '  %-*s   (project: shared, committed)\n' "$w" "$proj"
		printf '  %-*s   (project: only you, not committed)\n' "$w" "$local_settings"
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
