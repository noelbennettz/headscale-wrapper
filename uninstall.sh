#!/usr/bin/env bash
# Remove hs from /usr/local/bin/hs, from PREFIX/bin/hs, or from an exact path.
#
# Only touches the hs script itself: headscale, jq and any HS_DEFAULT_USER you
# exported in your shell profile are left alone.
#
# usage: ./uninstall.sh [--prefix DIR] [PATH] [--force]
set -euo pipefail

die() {
	printf 'uninstall: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
usage: ./uninstall.sh [--prefix DIR] [PATH] [--force]

  (no argument)    remove /usr/local/bin/hs
  --prefix DIR     remove DIR/bin/hs (the counterpart of install.sh --prefix)
  PATH             remove exactly PATH
  -f, --force      delete the file even when it does not look like hs

Environment:
  HS_SKIP_ROOT_CHECK=1   skip the write-access check (used by test/smoke.sh)
EOF
}

prefix=
dest=
force=0
while (($#)); do
	case $1 in
	-p | --prefix)
		shift
		(($#)) || die "--prefix needs a directory"
		prefix=$1
		dest=$prefix/bin/hs
		;;
	-f | --force) force=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		printf 'uninstall: unknown option: %s\n\n' "$1" >&2
		usage >&2
		exit 1
		;;
	*) dest=$1 ;;
	esac
	shift
done
dest=${dest:-/usr/local/bin/hs}

# The marker that identifies a file as ours, so we never delete a stranger.
marker='name-based wrapper around the headscale'

if [[ ! -e $dest ]]; then
	printf 'uninstall: %s is not installed (nothing to do)\n' "$dest"
	exit 0
fi

if ! grep -qF -- "$marker" "$dest" 2>/dev/null; then
	if ((force == 0)); then
		die "$dest does not look like hs, refusing (use --force to delete anyway)"
	fi
	printf 'uninstall: deleting %s even though it does not look like hs (--force)\n' "$dest" >&2
fi

if [[ ${HS_SKIP_ROOT_CHECK:-0} != 1 && ! -w $dest ]]; then
	die "$dest is not writable by $(id -un). Remove it with sudo, or delete the \
file yourself if you own the directory"
fi

rm -f -- "$dest"
printf 'removed %s\n' "$dest"

# Warn when another hs earlier in PATH would now shadow (or replace) it.
if other=$(command -v hs 2>/dev/null); then
	printf 'note: %s is still on PATH, check it if you expected hs to be gone\n' "$other" >&2
fi

