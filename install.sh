#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks and $PATH inside messages are literal
# Install hs to /usr/local/bin/hs, to PREFIX/bin/hs, or to an exact path.
#
# The only thing this script writes is the hs script itself. It never edits a
# shell profile, never installs headscale or jq and never creates directories
# outside the --prefix case.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: ./install.sh [--prefix DIR | PATH]

  (no argument)    install to /usr/local/bin/hs
  --prefix DIR     install to DIR/bin/hs, creating DIR/bin when it is missing
  PATH             install to exactly PATH (the directory has to exist)

Give either --prefix or PATH, not both.

Only the script itself is installed: headscale, jq and your shell profile are
left alone.

Environment:
  HS_SKIP_ROOT_CHECK=1   skip the write-access check (used by test/smoke.sh)
EOF
}

die() {
	printf 'install: %s\n' "$*" >&2
	exit 1
}

src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/hs

prefix=
dest=
while (($#)); do
	case $1 in
		-p | --prefix)
			shift
			# A missing value used to be taken from the next word even when
			# that word was another option, which made `--prefix --help`
			# create a directory called `--help`.
			[[ $# -gt 0 && -n $1 && $1 != -* ]] ||
				die "--prefix needs a directory, e.g. --prefix \"\$HOME/.local\""
			prefix=$1
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			printf 'install: unknown option: %s\n\n' "$1" >&2
			usage >&2
			exit 1
			;;
		*) dest=$1 ;;
	esac
	shift
done

if [[ -n $prefix && -n $dest ]]; then
	die "give either --prefix DIR or an explicit PATH, not both"
fi

[[ -f $src ]] || die "$src not found"
if [[ -n $prefix ]]; then
	dest=$prefix/bin/hs
fi
[[ -n $dest ]] || dest=/usr/local/bin/hs

# --prefix creates the bin directory; an explicit path does not, because a typo
# in the path should not silently create a tree.
if [[ -n $prefix ]]; then
	mkdir -p -- "$prefix/bin"
fi

dir=$(dirname -- "$dest")
[[ -d $dir ]] || die "$dir does not exist. Create it first (install -d -m 0755 $dir), \
or use --prefix to install under a prefix you own (e.g. --prefix \"\$HOME/.local\")"

if [[ ${HS_SKIP_ROOT_CHECK:-0} != 1 && ! -w $dir ]]; then
	die "$dir is not writable by $(id -un). Either run this with sudo, or install \
into a directory you own: ./install.sh --prefix \"\$HOME/.local\""
fi

install -m 0755 "$src" "$dest"
printf 'installed %s\n' "$dest"

for bin in jq headscale; do
	command -v "$bin" >/dev/null 2>&1 ||
		printf 'warning: %s not found, hs will complain about it at runtime\n' "$bin" >&2
done

# Two ways the install can look broken afterwards, both about PATH rather than
# about the file: the directory is not searched at all, or another hs wins.
case ":$PATH:" in
	*":$dir:"*) ;;
	*)
		printf 'note: %s is not in PATH, so plain `hs` will not find it. Add it:\n' "$dir" >&2
		printf '      export PATH="%s:$PATH"\n' "$dir" >&2
		;;
esac

found=$(command -v hs 2>/dev/null || true)
if [[ -n $found && $found != "$dest" ]]; then
	printf 'note: `hs` currently resolves to %s, which is not this install\n' "$found" >&2
fi
