#!/usr/bin/env bash
# Smoke tests for hs, driven by test/fakebin/headscale + test/fixtures.
# Run with: ./test/smoke.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
hs=$here/../hs
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export PATH=$here/fakebin:$PATH
export HS_LOG=$tmp/calls.log
: >"$HS_LOG"

pass=0
fail=0

ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}

ng() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n ${2:-} ]] && printf '     expected to contain: %s\n' "$2"
	[[ -n ${3:-} ]] && printf '     actual output: %s\n' "$3"
}

check_contains() {
	local name=$1 want=$2 got=$3
	if [[ $got == *"$want"* ]]; then ok "$name"; else ng "$name" "$want" "$got"; fi
}

check_status() {
	local name=$1 want=$2 got=$3
	if [[ $got == "$want" ]]; then ok "$name"; else ng "$name" "exit=$want" "exit=$got"; fi
}

# Clear the call log before each mutating command so we can assert on the
# exact arguments handed to headscale.
reset_log() { : >"$HS_LOG"; }

# check_calls <name> <pattern...>: every pattern must appear in the call log.
check_calls() {
	local name=$1 p
	shift
	for p in "$@"; do
		if ! grep -qF -- "$p" "$HS_LOG"; then
			ng "$name" "$p" "$(cat "$HS_LOG")"
			return
		fi
	done
	ok "$name"
}

# check_no_calls <name> <pattern...>: none of the patterns may be logged.
check_no_calls() {
	local name=$1 p
	shift
	for p in "$@"; do
		if grep -qF -- "$p" "$HS_LOG"; then
			ng "$name" "no \"$p\"" "$(cat "$HS_LOG")"
			return
		fi
	done
	ok "$name"
}

check_not_contains() {
	local name=$1 want=$2 got=$3
	if [[ $got == *"$want"* ]]; then ng "$name" "without $want" "$got"; else ok "$name"; fi
}

# ---------------------------------------------------------------- nodes

out=$("$hs" ls)
check_contains "ls: header" "NAME" "$out"
check_contains "ls: node appears in list" "laptop" "$out"
check_contains "ls: online state rendered" "offline" "$out"
if grep -q '[[:space:]]$' <<<"$out"; then
	ng "ls: no trailing whitespace" "" "$out"
else
	ok "ls: no trailing whitespace"
fi

out=$("$hs" show laptop)
check_contains "show: name resolved to ID" "ID          1" "$out"
check_contains "show: approved routes shown" "approved    192.168.1.0/24" "$out"

out=$("$hs" show 2)
check_contains "show: accepts an ID" "hostname    pixel-8" "$out"

out=$("$hs" show lap 2>&1)
check_status "show: ambiguous name exits 1" 1 $?
check_contains "show: ambiguous name lists candidates" "1:laptop, 3:laptop2" "$out"

# headscale-style spelling: hs node <verb> must reach the real verb instead of
# treating the verb as a user name.
out=$("$hs" node ls)
check_contains "node ls: header" "NAME" "$out"

out=$("$hs" nodes ls)
check_contains "nodes ls: header" "NAME" "$out"

out=$("$hs" node)
check_contains "node: bare word lists nodes" "laptop" "$out"

out=$("$hs" node show laptop)
check_contains "node show: name resolved to ID" "ID          1" "$out"

reset_log
"$hs" node rm phone --force >/dev/null
check_calls "node rm: deletes the node" "nodes delete -i 2 --force"

reset_log
"$hs" node rename phone pixel >/dev/null
check_calls "node rename: arguments" "nodes rename -i 2 pixel"

out=$("$hs" node nosuchverb 2>&1)
check_status "node: unknown subcommand exits 1" 1 $?
check_contains "node: unknown subcommand message" "unknown node subcommand: nosuchverb" "$out"
check_contains "node: user-filter hint" "hs ls <user>" "$out"
check_no_calls "node: verb is not sent as a user" "nodes list -u nosuchverb"

out=$("$hs" show nosuch 2>&1)
check_status "show: unknown node exits 1" 1 $?
check_contains "show: unknown node message" "no such node: nosuch" "$out"

# Matching is by prefix: a query that only appears inside a name must not match.
out=$("$hs" show top 2>&1)
check_status "show: substring does not match" 1 $?
check_contains "show: substring message" "no such node: top" "$out"

reset_log
out=$("$hs" rm phone 2>&1 </dev/null)
check_status "rm: refuses in non-interactive shell" 1 $?
check_contains "rm: non-interactive hint" "--force" "$out"

reset_log
out=$("$hs" rm phone --force)
check_contains "rm: confirmation message" "deleted phone (ID 2)" "$out"
check_calls "rm: headscale arguments" "nodes delete -i 2 --force"

reset_log
"$hs" rename phone pixel >/dev/null
check_calls "rename: arguments" "nodes rename -i 2 pixel"

reset_log
"$hs" tag phone tag:mobile tag:test >/dev/null
check_calls "tag: arguments" "nodes tag -i 2 -t tag:mobile -t tag:test"

# v0.29 rejects an empty tag list server-side, so hs must not send one.
reset_log
out=$("$hs" tag phone 2>&1)
check_status "tag: empty list refused" 1 $?
check_contains "tag: empty list hint" "cannot remove all tags" "$out"
check_no_calls "tag: not sent to headscale" "nodes tag"

reset_log
"$hs" expire phone >/dev/null
check_calls "expire: logout now" "nodes expire -i 2"

reset_log
"$hs" expire phone --at 2026-02-01T00:00:00Z >/dev/null
check_calls "expire: explicit timestamp" "nodes expire -i 2 -e 2026-02-01T00:00:00Z"

reset_log
"$hs" expire phone --disable >/dev/null
check_calls "expire: disable" "nodes expire -i 2 --disable"

reset_log
"$hs" expire phone --at 2026-02-01T08:00:00+08:00 >/dev/null
check_calls "expire: offset timestamp accepted" "nodes expire -i 2 -e 2026-02-01T08:00:00+08:00"

# --at must be RFC3339: reject the usual mistakes before calling headscale.
out=$("$hs" expire phone --at 24h 2>&1)
check_status "expire: duration rejected for --at" 1 $?
check_contains "expire: --at format hint" "RFC3339" "$out"

out=$("$hs" expire phone --at 2026-02-01 2>&1)
check_status "expire: date only rejected" 1 $?
check_contains "expire: timezone hint" "timezone" "$out"

out=$("$hs" expire phone --at '' 2>&1)
check_status "expire: empty --at rejected" 1 $?
check_contains "expire: empty --at hint" "--at needs a timestamp" "$out"

# ---------------------------------------------------------------- routes

out=$("$hs" route)
check_contains "route: lists nodes that have routes" "192.168.1.0/24" "$out"
check_not_contains "route: nodes without routes are hidden" "laptop2" "$out"

reset_log
out=$("$hs" route add laptop 10.10.0.0/16 172.16.0.0/12)
check_contains "route add: reports merged list" "10.10.0.0/16,172.16.0.0/12,192.168.1.0/24" "$out"
check_calls "route add: merges with existing approved routes" \
	"nodes approve-routes -i 1 -r 10.10.0.0/16,172.16.0.0/12,192.168.1.0/24"

reset_log
"$hs" route rm laptop >/dev/null
check_calls "route rm: no cidr withdraws everything" "nodes approve-routes -i 1 -r "

reset_log
"$hs" route rm laptop 192.168.1.0/24 >/dev/null
check_calls "route rm: last route leaves an empty list" "nodes approve-routes -i 1 -r "

# ---------------------------------------------------------------- address families
# A node gets an IPv4 address, an IPv6 address, both, or (before it registers)
# none. hs must print whatever headscale reports, unchanged - on hosts that are
# dual-stack, IPv4-only or IPv6-only alike, because it never opens a socket of
# its own (see the no-network checks at the end of this section).
fam=$tmp/fam
mkdir -p "$fam"
cat >"$fam/nodes.json" <<'EOF'
[
  {"id":1,"ip_addresses":["fd7a:115c:a1e0::101"],"name":"v6-host","user":{"id":1,"name":"alice"},"last_seen":{"seconds":1767225600},"given_name":"v6only","online":true,"tags":[]},
  {"id":2,"ip_addresses":["100.64.0.2"],"name":"v4-host","user":{"id":1,"name":"alice"},"last_seen":{"seconds":1767225600},"given_name":"v4only","online":true,"tags":[]},
  {"id":3,"ip_addresses":[],"name":"new-host","user":{"id":1,"name":"alice"},"given_name":"unassigned","online":false,"tags":[]},
  {"id":4,"ip_addresses":["100.64.0.4","2408:8916:a10:4cdf:d9ab:dead:4279:5738"],"name":"dual-host","user":{"id":1,"name":"alice"},"last_seen":{"seconds":1767225600},"given_name":"dual","online":true,"approved_routes":["192.168.0.0/24","fd00:dead:beef::/64"],"available_routes":["fd00:dead:beef::/64"],"tags":[]}
]
EOF
export FIXTURES=$fam

out=$("$hs" ls)
check_contains "families: IPv6-only node printed as-is" "fd7a:115c:a1e0::101" "$out"
check_contains "families: IPv4-only node printed as-is" "100.64.0.2" "$out"
check_contains "families: dual-stack node keeps both addresses" \
	"100.64.0.4,2408:8916:a10:4cdf:d9ab:dead:4279:5738" "$out"
# An empty ADDRESS must become "-": a blank middle column makes `column` shift
# ONLINE into the address column and misaligns every later row.
if grep -qE '^3[[:space:]]+unassigned[[:space:]]+alice[[:space:]]+-[[:space:]]+offline' <<<"$out"; then
	ok "families: node without an address keeps its columns"
else
	ng "families: node without an address keeps its columns" "- in ADDRESS" "$out"
fi

out=$("$hs" show v6only)
check_contains "families: show prints the IPv6 address" "address     fd7a:115c:a1e0::101" "$out"

out=$("$hs" show dual)
check_contains "families: show prints both addresses" \
	"address     100.64.0.4, 2408:8916:a10:4cdf:d9ab:dead:4279:5738" "$out"
check_contains "families: show prints IPv6 routes" \
	"approved    192.168.0.0/24, fd00:dead:beef::/64" "$out"

out=$("$hs" route)
check_contains "families: route lists IPv6 CIDRs" "fd00:dead:beef::/64" "$out"

reset_log
out=$("$hs" route add dual fd00:dead:beef:1::/64)
check_contains "families: IPv6 route reported" "fd00:dead:beef:1::/64" "$out"
check_calls "families: IPv6 route reaches headscale, IPv4 kept" \
	"nodes approve-routes -i 4" "192.168.0.0/24" "fd00:dead:beef:1::/64"

reset_log
"$hs" route rm dual fd00:dead:beef:1::/64 >/dev/null
check_calls "families: IPv6 route withdrawn, IPv4 kept" \
	"nodes approve-routes -i 4 -r 192.168.0.0/24,fd00:dead:beef::/64"

# The awk fallback (no util-linux column) must render IPv6 and "-" the same way.
nocol=$tmp/nocol
mkdir -p "$nocol"
for tool in bash jq awk sed cat rm mkdir mktemp head grep dirname; do
	ln -sf "$(command -v "$tool")" "$nocol/$tool"
done
ln -sf "$here/fakebin/headscale" "$nocol/headscale"
out=$(PATH="$nocol" "$hs" ls)
check_contains "families: awk fallback prints IPv6" "fd7a:115c:a1e0::101" "$out"
if grep -qE '^3[[:space:]]+unassigned[[:space:]]+alice[[:space:]]+-[[:space:]]+offline' <<<"$out"; then
	ok "families: awk fallback keeps the address column"
else
	ng "families: awk fallback keeps the address column" "- in ADDRESS" "$out"
fi

# hs itself must not depend on the host having an IPv4 or an IPv6 stack: it only
# execs the local headscale binary, so no AF_INET/AF_INET6 socket is created.
if command -v strace >/dev/null 2>&1; then
	strace -f -qq -e trace=%network -o "$tmp/net.trace" "$hs" ls >/dev/null 2>&1
	if grep -q 'AF_INET' "$tmp/net.trace"; then
		ng "host: no IPv4/IPv6 sockets" "no AF_INET socket" \
			"$(grep -m1 'AF_INET' "$tmp/net.trace")"
	else
		ok "host: no IPv4/IPv6 sockets"
	fi
fi

# The same read command with networking unshared entirely: works as long as the
# local headscale does, which is what an IPv4-only or IPv6-only host looks like
# to hs.
if command -v bwrap >/dev/null 2>&1 &&
	bwrap --unshare-net --ro-bind / / --dev /dev true >/dev/null 2>&1; then
	# The generated fixtures live under /tmp, which the sandbox replaces with an
	# empty tmpfs, so this run uses the checked-in fixtures.
	unset FIXTURES
	out=$(HS_LOG=/dev/null bwrap --unshare-net --ro-bind / / --dev /dev \
		--proc /proc --tmpfs /tmp "$hs" ls 2>&1)
	check_status "host: works with the network unshared" 0 $?
	check_contains "host: IPv6 node visible with no network" \
		"fd7a:115c:a1e0::1" "$out"
fi

unset FIXTURES

# ---------------------------------------------------------------- pre-auth keys

reset_log
out=$("$hs" key new -u alice -e 24h -r -E -t tag:vpn)
check_contains "key new: prints the key only" "preauthkey-abc123" "$out"
check_calls "key new: user name resolved to ID" \
	"preauthkeys create -u 1 -e 24h --reusable --ephemeral --tags tag:vpn"

reset_log
out=$(HS_DEFAULT_USER=bob "$hs" key new -e 30m)
check_calls "key new: HS_DEFAULT_USER honored" "preauthkeys create -u 2 -e 30m"

out=$("$hs" key ls)
check_contains "key ls: lists keys" "pk-aaaaaaaaaaaa" "$out"
check_contains "key ls: tags take precedence over owner" "tag:mobile" "$out"

reset_log
out=$("$hs" key rm 1 2)
check_contains "key rm: multiple IDs" "key 2" "$out"
check_calls "key rm: arguments" "preauthkeys delete -i 1" "preauthkeys delete -i 2"

out=$("$hs" key rm abc 2>&1)
check_status "key rm: rejects non-numeric ID" 1 $?

out=$("$hs" key rm 0 2>&1)
check_status "key rm: rejects ID 0" 1 $?
check_contains "key rm: ID 0 hint" "must be 1 or greater" "$out"

out=$("$hs" key new -u alice -e '' 2>&1)
check_status "key new: empty -e rejected" 1 $?
check_contains "key new: -e hint" "needs a duration" "$out"

reset_log
"$hs" key expire 2 >/dev/null
check_calls "key expire: arguments" "preauthkeys expire -i 2"

# ---------------------------------------------------------------- users

out=$("$hs" user ls)
check_contains "user ls: lists users" "alice@example.com" "$out"

reset_log
"$hs" user new carol >/dev/null
check_calls "user new: arguments" "users create carol"

reset_log
"$hs" user rm bob --force >/dev/null
check_calls "user rm: by name" "users destroy --name bob --force"

reset_log
"$hs" user rm 2 --force >/dev/null
check_calls "user rm: by ID" "users destroy --identifier 2 --force"

out=$("$hs" user rm 0 --force 2>&1)
check_status "user rm: rejects ID 0" 1 $?
check_contains "user rm: ID 0 hint" "must be 1 or greater" "$out"

# ---------------------------------------------------------------- json output

# check_json <name> <jq filter> <json>
check_json() {
	local name=$1 filter=$2 json=$3
	if jq -e "$filter" <<<"$json" >/dev/null 2>&1; then
		ok "$name"
	else
		ng "$name" "$filter" "$json"
	fi
}

out=$("$hs" ls --json)
check_status "ls --json: exits 0" 0 $?
check_json "ls --json: headscale array" 'length == 3 and .[0].given_name == "laptop"' "$out"
check_not_contains "ls --json: no table header" "ID  NAME" "$out"
if [[ $out == "$(cat "$here/fixtures/nodes.json")" ]]; then
	ok "ls --json: passed through unchanged"
else
	ng "ls --json: passed through unchanged" "" "$out"
fi

out=$("$hs" --json ls)
check_json "--json before the command" 'length == 3' "$out"

out=$("$hs" ls alice --json)
check_json "ls --json: user argument still reaches headscale" 'length == 3' "$out"

out=$("$hs" show laptop --json)
check_json "show --json: single node object" '.id == 1 and .given_name == "laptop"' "$out"
check_not_contains "show --json: no label columns" "ID          " "$out"

out=$("$hs" show 2 --json)
check_json "show --json: accepts an ID" '.name == "pixel-8"' "$out"

out=$("$hs" show lap --json 2>&1)
check_status "show --json: ambiguity is still an error" 1 $?
check_contains "show --json: ambiguity lists candidates" "1:laptop, 3:laptop2" "$out"

out=$("$hs" route --json)
check_json "route --json: only nodes with routes" 'length == 1 and .[0].id == 1' "$out"
check_not_contains "route --json: no table header" "APPROVED" "$out"

out=$("$hs" route laptop --json)
check_json "route --json: one node stays an array" 'length == 1 and .[0].approved_routes == ["192.168.1.0/24"]' "$out"

out=$("$hs" route phone --json)
check_json "route --json: a node without routes is an empty array" 'length == 0' "$out"

out=$("$hs" key ls --json)
check_json "key ls --json" 'length == 2 and .[0].id == 1' "$out"
check_not_contains "key ls --json: no table header" "REUSABLE" "$out"

out=$("$hs" user ls --json)
check_json "user ls --json" 'length == 2 and .[0].name == "alice"' "$out"

out=$("$hs" version --json)
check_json "version --json: version parsed" '.version == "0.29.0"' "$out"
check_json "version --json: raw text kept" '.raw | startswith("headscale version")' "$out"

out=$("$hs" help)
check_contains "help: documents --json" "--json" "$out"

# ---------------------------------------------------------------- dry-run

# A dry run must not care about the TTY: the suite runs without one, and the
# whole point is inspecting a destructive command from a script or a cron job.
reset_log
out=$("$hs" rm phone --dry-run)
check_status "dry-run: rm works without --force or a TTY" 0 $?
check_contains "dry-run: rm command printed" "dry-run: headscale nodes delete -i 2" "$out"
check_not_contains "dry-run: rm reports no deletion" "deleted" "$out"
check_no_calls "dry-run: rm did not call headscale" "nodes delete"

reset_log
out=$("$hs" rm phone laptop --force --dry-run)
check_contains "dry-run: --force appears in the printed command" "nodes delete -i 2 --force" "$out"
check_contains "dry-run: one line per node" "nodes delete -i 1 --force" "$out"
check_no_calls "dry-run: neither node was deleted" "nodes delete"

reset_log
out=$("$hs" rename phone pixel --dry-run)
check_contains "dry-run: rename" "dry-run: headscale nodes rename -i 2 pixel" "$out"
check_no_calls "dry-run: rename did not run" "nodes rename"

reset_log
out=$("$hs" tag laptop tag:a tag:b --dry-run)
check_contains "dry-run: tag" "nodes tag -i 1 -t tag:a -t tag:b" "$out"
check_no_calls "dry-run: tag did not run" "nodes tag"

reset_log
out=$("$hs" expire laptop --at 2026-02-01T00:00:00Z --dry-run)
check_contains "dry-run: expire --at" "nodes expire -i 1 -e 2026-02-01T00:00:00Z" "$out"
out=$("$hs" expire laptop --disable --dry-run)
check_contains "dry-run: expire --disable" "nodes expire -i 1 --disable" "$out"
check_no_calls "dry-run: expire did not run" "nodes expire"

reset_log
out=$("$hs" route add laptop 10.0.0.0/8 --dry-run)
check_contains "dry-run: route add prints the merged list" \
	"nodes approve-routes -i 1 -r 10.0.0.0/8,192.168.1.0/24" "$out"
out=$("$hs" route rm laptop 192.168.1.0/24 --dry-run)
check_contains "dry-run: route rm prints the remaining list" "nodes approve-routes -i 1 -r ''" "$out"
out=$("$hs" route rm phone --dry-run)
check_contains "dry-run: route rm without a CIDR withdraws all" "nodes approve-routes -i 2 -r ''" "$out"
check_no_calls "dry-run: routes were not changed" "approve-routes"

reset_log
out=$("$hs" key new -u alice -e 24h -r -t tag:vpn --dry-run)
check_contains "dry-run: key new" "preauthkeys create -u 1 -e 24h --reusable --tags tag:vpn" "$out"
out=$("$hs" key rm 1 2 --dry-run)
check_contains "dry-run: key rm prints every ID" "preauthkeys delete -i 2" "$out"
out=$("$hs" key expire 2 --dry-run)
check_contains "dry-run: key expire" "preauthkeys expire -i 2" "$out"
check_no_calls "dry-run: keys untouched" "preauthkeys create" "preauthkeys delete"

reset_log
out=$("$hs" user new carol --dry-run)
check_contains "dry-run: user new" "dry-run: headscale users create carol" "$out"
out=$("$hs" user rm bob --dry-run)
check_status "dry-run: user rm works without --force" 0 $?
check_contains "dry-run: user rm" "users destroy --name bob" "$out"
check_no_calls "dry-run: users untouched" "users create" "users destroy"

reset_log
out=$("$hs" rm nosuchnode --dry-run 2>&1)
check_status "dry-run: an unknown node still fails" 1 $?
check_contains "dry-run: unknown node message" "no such node: nosuchnode" "$out"

# Read commands ignore the flag: they only read, and the output is unchanged.
out=$("$hs" ls --dry-run)
check_contains "dry-run: read commands still print the table" "laptop" "$out"
check_not_contains "dry-run: read commands print no dry-run line" "dry-run:" "$out"

out=$("$hs" help)
check_contains "help: documents --dry-run" "--dry-run" "$out"

# ---------------------------------------------------------------- deps and errors

out=$("$hs" version)
check_contains "version" "0.29.0" "$out"

out=$("$hs" nosuchcmd 2>&1)
check_status "unknown command exits 1" 1 $?
check_contains "unknown command message" "unknown command: nosuchcmd" "$out"

# A failing headscale must surface its own message, not swallow it; the
# "rpc error: code = Unknown desc = " noise is stripped.
cat >"$tmp/failing-headscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"error": "listing nodes: rpc error: code = Unknown desc = user not found"}' >&2
exit 1
EOF
chmod +x "$tmp/failing-headscale"
out=$(HS_HEADSCALE_BIN="$tmp/failing-headscale" "$hs" ls rm 2>&1)
check_status "headscale failure: exits 1" 1 $?
check_contains "headscale failure: keeps the cause" \
	"failed to list nodes (user: rm): user not found" "$out"
check_not_contains "headscale failure: noise stripped" "desc = " "$out"
check_contains "headscale failure: user hint" "hs user ls" "$out"

# Missing jq: PATH holds only bash and the fake headscale, so hs must stop
# with a hint instead of failing somewhere in the middle.
mkdir -p "$tmp/nojq"
ln -sf "$(command -v bash)" "$tmp/nojq/bash"
ln -sf "$here/fakebin/headscale" "$tmp/nojq/headscale"
out=$(PATH="$tmp/nojq" "$hs" ls 2>&1)
check_status "missing jq: exits 1" 1 $?
check_contains "missing jq: install hint" "jq not found" "$out"
check_not_contains "missing jq: no other output" "preauthkey" "$out"

out=$(PATH=/usr/bin:/bin HS_HEADSCALE_BIN=/nonexistent/headscale "$hs" ls 2>&1)
check_status "missing headscale: exits 1" 1 $?
check_contains "missing headscale: hint" "headscale binary not found" "$out"

# Help is a static text: it must not depend on jq or headscale being installed.
# ($tmp/nojq already lost `cat`, so add it back: coreutils are not under test.)
ln -sf "$(command -v cat)" "$tmp/nojq/cat"
out=$(PATH="$tmp/nojq" HS_HEADSCALE_BIN=/nonexistent/headscale "$hs" help 2>&1)
check_status "help: works without deps" 0 $?
check_contains "help: documents the node spelling" "hs node <verb>" "$out"
check_contains "help: documents single-stack hosts" "IPv4-only and IPv6-only" "$out"

# ---------------------------------------------------------------- install / uninstall

bindir=$tmp/bin
mkdir -p "$bindir"

out=$(HS_SKIP_ROOT_CHECK=1 "$here/../install.sh" "$bindir/hs" 2>&1)
check_status "install: succeeds" 0 $?
if [[ -x $bindir/hs ]]; then
	ok "install: file is executable"
else
	ng "install: file is executable"
fi

out=$(PATH=$here/fakebin:$bindir:$PATH "$bindir/hs" version 2>&1)
check_contains "install: installed copy runs" "0.29.0" "$out"

# A foreign file must not be deleted by accident.
printf '#!/bin/sh\necho not hs\n' >"$tmp/stranger"
out=$(HS_SKIP_ROOT_CHECK=1 "$here/../uninstall.sh" "$tmp/stranger" 2>&1)
check_status "uninstall: refuses unknown file" 1 $?
if [[ -f $tmp/stranger ]]; then
	ok "uninstall: unknown file kept"
else
	ng "uninstall: unknown file kept"
fi

out=$(HS_SKIP_ROOT_CHECK=1 "$here/../uninstall.sh" "$bindir/hs" 2>&1)
check_status "uninstall: succeeds" 0 $?
if [[ -e $bindir/hs ]]; then
	ng "uninstall: file removed" "" "still present"
else
	ok "uninstall: file removed"
fi

out=$(HS_SKIP_ROOT_CHECK=1 "$here/../uninstall.sh" "$bindir/hs" 2>&1)
check_status "uninstall: idempotent" 0 $?
check_contains "uninstall: reports nothing to do" "not installed" "$out"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
