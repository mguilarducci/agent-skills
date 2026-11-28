#!/usr/bin/env bash
# hc-worktree: what herdr-app's "New worktree" dialog does, from the shell.
#
# Mirrors create() in the shipped mod (~/.config/herdr-app/mods/worktree/main.js):
# same folder, same slug, same git commands, same unnamed space.
# Runs on macOS's stock bash 3.2. Needs git, perl and herdr-app.

set -u

VERSION="0.1.0"
PROG="hc-worktree"

print_help() {
	cat <<HELP
$PROG - open a new Herdr space on a git worktree, like the New worktree dialog

Usage:
  $PROG [--no-focus] <branch>
  $PROG --help | --version

Run it inside a git repo (the main checkout or any of its worktrees).

  - The checkout goes to <worktrees.directory>/<repo>/<slug(branch)>.
    worktrees.directory comes from \$HERDR_APP_HOME/settings.json
    (default ~/.config/herdr-app), else ~/.herdr/worktrees. <repo> is
    the main checkout's folder name, even when run from a worktree.
  - An existing local branch is checked out; a new one starts from the
    current HEAD (not main), as the dialog does.
  - Then herdr-app opens an unnamed space in that folder, so it follows
    the folder and nests under the repo in the sidebar.

Flags:
  --no-focus     Create the space without switching to it.
  -h, --help     Show this help.
  --version      Print the version.

Output: the worktree path on stdout; progress and errors on stderr.

Exit codes:
  0  worktree and space created
  1  git worktree add or herdr-app failed
  2  usage error
  4  not in a git repo, a bad worktrees.directory, or git, perl or
     herdr-app missing
HELP
}

die() {
	local code="$1"
	shift
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit "$code"
}

usage_error() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	printf "Run '%s --help' for usage.\n" "$PROG" >&2
	exit 2
}

# The dialog's slug: NFC, each run outside letters/marks/digits/._- becomes
# "-", dashes trimmed; a symbol-only name gets an FNV-1a hash instead.
slugify() {
	perl -CSA -MUnicode::Normalize -e '
		my $n = NFC($ARGV[0]);
		(my $s = $n) =~ s/[^\p{L}\p{M}\p{N}._-]+/-/g;
		$s =~ s/^-+|-+$//g;
		if ($s eq "") {
			my $h = 2166136261;
			for my $c (split //, $n) {
				$h = ($h ^ ord($c)) & 0xFFFFFFFF;
				$h = ($h * 16777619) & 0xFFFFFFFF; # fits in a 64-bit integer
			}
			$s = sprintf("branch-%08x", $h);
		}
		print $s;
	' "$1"
}

# worktrees.directory resolved like the dialog: ~ expanded, absolute, no
# trailing slash. Prints the path, or an error on stderr and exits 1.
worktrees_root() {
	local settings="${HERDR_APP_HOME:-$HOME/.config/herdr-app}/settings.json"
	perl -MJSON::PP -e '
		my ($file, $home) = @ARGV;
		my $dir = "~/.herdr/worktrees";
		if (open(my $fh, "<", $file)) {
			local $/;
			my $cfg = JSON::PP->new->decode(<$fh>);
			$dir = $cfg->{worktrees}{directory}
				if ref $cfg eq "HASH" && ref $cfg->{worktrees} eq "HASH"
				&& exists $cfg->{worktrees}{directory} && defined $cfg->{worktrees}{directory};
		}
		die "worktrees.directory must be a non-empty path.\n" if ref $dir || $dir !~ /\S/;
		$dir =~ s{\\}{/}g;
		if ($dir eq "~" || $dir =~ m{^~/}) { (my $h = $home) =~ s{/$}{}; $dir = $h . substr($dir, 1); }
		die "worktrees.directory must be an absolute path or start with ~/.\n" unless $dir =~ m{^/};
		$dir =~ s{/+$}{};
		print $dir;
	' "$settings" "$HOME"
}

main() {
	local focus=true branch="" have_branch=false
	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help)
			print_help
			exit 0
			;;
		--version)
			printf '%s %s\n' "$PROG" "$VERSION"
			exit 0
			;;
		--no-focus) focus=false ;;
		--)
			shift
			[ $# -gt 0 ] || break
			$have_branch && usage_error "expected one branch, got more"
			branch="$1"
			have_branch=true
			shift
			[ $# -eq 0 ] || usage_error "expected one branch, got more"
			break
			;;
		-*) usage_error "unknown flag: $1" ;;
		*)
			$have_branch && usage_error "expected one branch, got more"
			branch="$1"
			have_branch=true
			;;
		esac
		shift
	done

	# The dialog trims what was typed.
	branch="$(printf '%s' "$branch" | perl -0777 -pe 's/^\s+|\s+$//g')"
	[ -n "$branch" ] || usage_error "missing branch name"

	command -v git >/dev/null 2>&1 || die 4 "git not found on PATH"
	command -v perl >/dev/null 2>&1 || die 4 "perl not found on PATH"
	command -v herdr-app >/dev/null 2>&1 || die 4 "herdr-app not found on PATH"

	local top common repo_main name
	if ! top="$(git rev-parse --show-toplevel 2>/dev/null)" ||
		! common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
		die 4 "$(pwd) is not in a git repository"
	fi
	repo_main="${common%/.git}"
	name="$(basename "$repo_main")"
	# A bare repo hidden beside its worktrees (<project>/.bare) is named after its project.
	[ "$name" = ".bare" ] && name="$(basename "$(dirname "$repo_main")")"

	local root slug path
	root="$(worktrees_root)" || die 4 "can't read worktrees.directory"
	slug="$(slugify "$branch")"
	path="$root/$name/$slug"

	local out
	if git -C "$repo_main" show-ref --verify --quiet "refs/heads/$branch"; then
		printf '%s: checking out branch %s in %s\n' "$PROG" "$branch" "$path" >&2
		out="$(git -C "$top" worktree add "$path" "$branch" 2>&1)" || die 1 "${out:-git worktree add failed.}"
	else
		printf '%s: creating branch %s from HEAD in %s\n' "$PROG" "$branch" "$path" >&2
		out="$(git -C "$top" worktree add -b "$branch" "$path" HEAD 2>&1)" || die 1 "${out:-git worktree add failed.}"
	fi

	# Unnamed on purpose: the space follows the checkout folder and nests under the repo.
	local args
	args="$(perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode({folder => $ARGV[0], machine => "", ($ARGV[1] eq "false" ? (focus => JSON::PP::false) : ())})' "$path" "$focus")"
	if ! out="$(herdr-app "do" space.new "$args" 2>&1)" || printf '%s' "$out" | grep -q '"error"'; then
		printf '%s: herdr-app space.new failed: %s\n' "$PROG" "$out" >&2
		printf '%s: the worktree was kept: %s (remove it with: git worktree remove %q)\n' "$PROG" "$path" "$path" >&2
		exit 1
	fi

	printf '%s\n' "$path"
}

main "$@"
