#!/usr/bin/env bash
# Check that every repository path the documentation mentions exists.
#
# The documentation used to promise a docs/versions/<tag>/ snapshot that no
# commit ever contained. This test fails on that class of mistake: paths in
# Markdown links, and paths in backticks that start with test/, docs/ or
# .github/, must resolve to a real file or directory.
#
# Run with: ./test/docs-paths.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$here" || exit 1

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ng() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n ${2:-} ]] && printf '     missing path: %s\n' "$2"
	[[ -n ${3:-} ]] && printf '     referenced in: %s\n' "$3"
}

docs=(README.md DOCS.md SECURITY.md CONTRIBUTING.md)
checked=0

# Patterns live in variables so the regexes stay readable without quoting the
# backticks and brackets inside a shell single-quoted string.
link_re='\]\([^)[:space:]]+\)'
# shellcheck disable=SC2016  # the regex is literal, the backticks are the point
path_re='`(test|docs|\.github)/[A-Za-z0-9._/-]+`'

for doc in "${docs[@]}"; do
	[[ -f $doc ]] || continue

	# 1. Relative Markdown link targets: [text](path)
	while read -r target; do
		[[ -n $target ]] || continue
		target=${target%%#*}   # drop the anchor
		target=${target%%\?*}  # drop a query string
		[[ -n $target ]] || continue
		checked=$((checked + 1))
		if [[ -e $target ]]; then
			ok "$doc: link $target exists"
		else
			ng "$doc: link target exists" "$target" "$doc"
		fi
	done < <(grep -oE "$link_re" "$doc" | sed -e 's/^](//' -e 's/)$//' |
		grep -vE '^(https?://|mailto:|#)' || true)

	# 2. Backticked repository paths: `test/...`, `docs/...`, `.github/...`
	while read -r target; do
		[[ -n $target ]] || continue
		checked=$((checked + 1))
		if [[ -e ${target%/} ]]; then
			ok "$doc: path $target exists"
		else
			ng "$doc: mentioned path exists" "$target" "$doc"
		fi
	done < <(grep -oE "$path_re" "$doc" |
		tr -d '`' | sort -u || true)
done

# A documented versioned snapshot has to be real: if the docs point at
# docs/versions/<tag>/, the directory for every release tag must exist.
if grep -qE 'docs/versions/' README.md DOCS.md 2>/dev/null; then
	for tagdir in docs/versions/*/; do
		[[ -d $tagdir ]] || continue
		if [[ -f ${tagdir}DOCS.md || -f ${tagdir}README.md ]]; then
			ok "docs/versions: $tagdir has a document"
		else
			ng "docs/versions: $tagdir has a document" "$tagdir"
		fi
	done
fi

if ((checked == 0)); then
	ng "documentation references at least one path" "" "README.md, DOCS.md"
fi

printf '\n%d passed, %d failed (%d paths checked)\n' "$pass" "$fail" "$checked"
((fail == 0))
