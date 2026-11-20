#!/usr/bin/env bash
# hs - a small, name-based wrapper around the headscale (v0.29) CLI.
#
# Goal: replace headscale's "--identifier <id>" workflow with name-based
# commands and stable, readable output that is safe to pipe.
#
# Requirements: headscale (verified against v0.29) and jq.
# Environment: HS_HEADSCALE_BIN (default: headscale), HS_DEFAULT_USER.
set -euo pipefail

PROG=${0##*/}
HEADSCALE_BIN=${HS_HEADSCALE_BIN:-headscale}

# --json turns every read command into a JSON printer: the headscale JSON is
# passed through instead of being formatted into a table.
JSON=0

# --dry-run resolves names as usual but prints the headscale command it would
# have run instead of running it, so the destructive commands can be inspected
# (and scripted) without prompts.
DRY_RUN=0

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
usage: hs <command> [args]

Nodes
  hs ls [user]                    List nodes (optionally filtered by user)
  hs node <verb> ...              Same commands spelled headscale-style, e.g.
                                  hs node rm gw-fmt-1 (= hs rm gw-fmt-1)
  hs show <node>                  Show details for a single node
  hs rm <node...> [--force]       Delete nodes (asks for confirmation)
  hs rename <node> <new-name>     Rename a node
  hs tag <node> <tag...>          Overwrite tags (headscale checks the format:
                                  tag:lowercase)
  hs expire <node> [--at TIME]    Log out a node / set its expiry; --at takes
                                  an RFC3339 timestamp (2026-02-01T00:00:00Z)
  hs expire <node> --disable      Disable expiry (node never expires)

Routes (subnet routes)
  hs route [node]                 List nodes that have routes (or just one)
  hs route add <node> <cidr...>   Approve routes (merged with existing ones)
  hs route rm <node> [cidr...]    Withdraw routes (no cidr = withdraw all)

Pre-auth keys
  hs key new [-u user] [-e 24h] [-r] [-E] [-t tag]
                                  Create a preauthkey (-e is a duration from
                                  now: 30m, 24h, 7d; default 1h); -r reusable,
                                  -E ephemeral
  hs key ls                       List keys
  hs key rm <id...>               Delete keys
  hs key expire <id...>           Expire keys immediately

Users
  hs user ls                      List users
  hs user new <name>              Create a user
  hs user rm <name|id> [--force]  Delete a user (asks for confirmation)

Other
  hs version                      Show the headscale version
  hs help                         Show this help

  hs <read command> --json        Print the headscale JSON instead of a table
                                  (ls, show, route, key ls, user ls, version);
                                  --json may also come first: hs --json ls

  hs <write command> --dry-run    Resolve the names and print the headscale
                                  command instead of running it; no prompt, no
                                  confirmation, nothing changes

<node> accepts an ID or a name (given_name, then hostname); names also match
on a unique prefix. IDs are numbers starting at 1.

Timestamps (--at) are RFC3339 with a timezone; durations (-e) are whole numbers
with a unit, largest first (y w d h m s ms), e.g. 1d12h; the default is 1h.
Careful: -e is a timestamp in "hs expire" but a duration in "hs key new".

IPv4 and IPv6 node addresses and route CIDRs are passed through unchanged; hs
opens no socket itself, so IPv4-only and IPv6-only hosts work the same way.
EOF
}

# ---------------------------------------------------------------- dependencies

require_deps() {
	command -v jq >/dev/null 2>&1 ||
		die "jq not found. Install it first (Debian/Ubuntu: apt-get install -y jq," \
			"RHEL family: dnf install -y jq)"
	command -v "$HEADSCALE_BIN" >/dev/null 2>&1 ||
		die "headscale binary not found ($HEADSCALE_BIN). Check the installation or set HS_HEADSCALE_BIN"
}

# ---------------------------------------------------------------- helpers

# render_table: turn TSV on stdin into an aligned table; falls back to awk
# when column(1) is unavailable. Trailing padding is stripped either way so
# the output stays clean when piped.
render_table() {
	if command -v column >/dev/null 2>&1; then
		column -t -s $'\t' | sed -e 's/[[:space:]]*$//'
	else
		awk -F'\t' '
			{ n = (NF > n ? NF : n)
			  for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
			END {
			  for (r = 1; r <= NR; r++) {
			    line = ""
			    for (i = 1; i <= n; i++) line = line sprintf("%-*s", w[i] + 2, cell[r, i])
			    sub(/[ \t]+$/, "", line)
			    print line
			  }
			}'
	fi
}

# as_list: headscale marshals an empty repeated field as `null`, not `[]`, so
# a server with no nodes, keys or users answers `null`. Every consumer here
# iterates with jq (.[], map), which fails on null, so normalise it once.
as_list() {
	local json=$1
	if [[ $json == null || -z $json ]]; then
		printf '[]\n'
	else
		printf '%s\n' "$json"
	fi
}

# Shared jq prelude: render a protobuf timestamp ({seconds,nanos}) as UTC and
# a list as "a, b" ("-" when it is missing or empty).
# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
JQ_LIB='
def ts:
  (. // 0) as $s
  | if $s == 0 or $s == null then "-" else ($s | todate) end;

def lst:
  ((. // []) | join(", ")) | if . == "" then "-" else . end;

def csl:
  ((. // []) | join(",")) | if . == "" then "-" else . end;
'

# ---------------------------------------------------------------- data access

NODES_JSON=""

# headscale reports gRPC failures as a one-line JSON object on stderr, e.g.
#   {"error": "listing nodes: rpc error: code = Unknown desc = user not found"}
# Keep the description only; the "rpc error: code = Unknown desc = " prefix
# tells the user nothing. Plain-text errors fall back to their first line.
extract_error() {
	local raw=$1 msg=""
	msg=$(jq -r '(.error // .message // empty)' <<<"$raw" 2>/dev/null || true)
	[[ -n $msg ]] || msg=$(printf '%s\n' "$raw" | grep -m1 -v '^[[:space:]]*$' || true)
	msg=${msg#*desc = }
	printf '%s' "${msg:0:200}"
}

load_nodes() {
	local user=${1:-} err rc=0 raw msg
	err=$(mktemp "${TMPDIR:-/tmp}/hs-err.XXXXXX") || die "cannot create a temporary file"

	if [[ -n $user ]]; then
		NODES_JSON=$("$HEADSCALE_BIN" nodes list -u "$user" -o json 2>"$err") || rc=$?
	else
		NODES_JSON=$("$HEADSCALE_BIN" nodes list -o json 2>"$err") || rc=$?
	fi

	if ((rc != 0)); then
		raw=$(cat "$err")
		rm -f "$err"
		[[ -n $raw ]] || raw=$NODES_JSON
		msg=$(extract_error "$raw")
		if [[ -n $user ]]; then
			die "failed to list nodes (user: $user): ${msg:-unknown error} (hs user ls lists the users)"
		fi
		die "failed to list nodes: ${msg:-unknown error}"
	fi
	rm -f "$err"
	NODES_JSON=$(as_list "$NODES_JSON")
}

# The node cache has to be filled in the parent shell: helpers such as
# resolve_node run inside $( ), so a cache set there never reaches us.
ensure_nodes() {
	[[ -n ${NODES_JSON:-} ]] || load_nodes
}

# Resolve "ID or name" to a node ID and print the bare number.
resolve_node() {
	local q=$1
	[[ -n $q ]] || die "missing node argument"
	[[ -n $NODES_JSON ]] || load_nodes

	local out
	out=$(jq -r --arg q "$q" "$JQ_LIB"'
		( map(select((.id | tostring) == $q)) ) as $byid
		| if ($byid | length) == 1 then $byid[0].id
		  else
			( map(select((.given_name // "") == $q or (.name // "") == $q)) ) as $exact
			| if ($exact | length) == 1 then $exact[0].id
			  elif ($exact | length) > 1 then
				"AMBIG:" + ([$exact[] | "\(.id):\(.given_name // .name)"] | join(", "))
			  else
				( map(select(((.given_name // "") | startswith($q))
					or ((.name // "") | startswith($q)))) ) as $fuzzy
				| if ($fuzzy | length) == 1 then $fuzzy[0].id
				  elif ($fuzzy | length) == 0 then "NOTFOUND"
				  else "AMBIG:" + ([$fuzzy[] | "\(.id):\(.given_name // .name)"] | join(", "))
				  end
			  end
		  end' <<<"$NODES_JSON")

	case $out in
		NOTFOUND) die "no such node: $q" ;;
		AMBIG:*) die "ambiguous node name: $q matches several (${out#AMBIG:}), use the ID instead" ;;
		"") die "failed to resolve node: $q" ;;
		*) printf '%s\n' "$out" ;;
	esac
}

node_display_name() {
	local id=$1
	jq -r --argjson id "$id" \
		'.[] | select(.id == $id) | (.given_name // .name // "-")' <<<"$NODES_JSON"
}

# Print a node's approved routes as a comma-separated list ("" when none).
# approve-routes is a replace operation, so callers merge against this list.
approved_routes_of() {
	local id=$1
	jq -r --argjson id "$id" \
		'.[] | select(.id == $id) | (.approved_routes // []) | join(",")' <<<"$NODES_JSON"
}

resolve_user() {
	local q=${1:-${HS_DEFAULT_USER:-}}
	local users
	users=$("$HEADSCALE_BIN" users list -o json) || die "failed to list users"
	users=$(as_list "$users")

	if [[ -z $q ]]; then
		local count
		count=$(jq -r 'length' <<<"$users")
		if [[ $count == 1 ]]; then
			jq -r '.[0].id' <<<"$users"
			return 0
		fi
		die "a user is required: hs key new -u <name> ($count users exist)"
	fi

	local out
	out=$(jq -r --arg q "$q" '
		( map(select((.id | tostring) == $q)) ) as $byid
		| if ($byid | length) == 1 then $byid[0].id
		  else
			( map(select(.name == $q)) ) as $exact
			| if ($exact | length) == 1 then $exact[0].id
			  elif ($exact | length) == 0 then "NOTFOUND"
			  else "AMBIG:" + ([$exact[] | "\(.id):\(.name)"] | join(", "))
			  end
		  end' <<<"$users")

	case $out in
		NOTFOUND) die "no such user: $q" ;;
		AMBIG:*) die "ambiguous user: $q (${out#AMBIG:})" ;;
		"") die "failed to resolve user: $q" ;;
		*) printf '%s\n' "$out" ;;
	esac
}

confirm() {
	local prompt=$1 answer
	if [[ ! -t 0 ]]; then
		die "non-interactive shell, pass --force to run anyway ($prompt)"
	fi
	read -r -p "$prompt [y/N] " answer || true
	[[ $answer == [yY]* ]]
}

# print_dry_run <args...>: the headscale invocation --dry-run would have made,
# shell-quoted on one line so it can be copied into a shell.
quote_arg() {
	local a=$1
	if [[ $a =~ ^[A-Za-z0-9_./:@%+,=-]+$ ]]; then
		printf '%s' "$a"
	else
		printf '%q' "$a"
	fi
}

print_dry_run() {
	local out="" a
	out=$(quote_arg "$HEADSCALE_BIN")
	for a in "$@"; do
		out+=" $(quote_arg "$a")"
	done
	printf 'dry-run: %s\n' "$out"
}

# validate_rfc3339: reject the mistakes users actually make (date only, no
# timezone, epoch seconds, a duration instead of a timestamp) locally, so the
# hint is immediate instead of a headscale "parsing expiry time" error.
# It is a shape check only; headscale still decides what the value means.
validate_rfc3339() {
	local value=$1
	local pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
	[[ -n $value ]] ||
		die "--at needs a timestamp, e.g. 2026-02-01T00:00:00Z (see hs help)"
	[[ $value =~ $pattern ]] || die \
		"--at takes an RFC3339 timestamp with a timezone, e.g. 2026-02-01T00:00:00Z" \
		"or 2026-02-01T08:00:00+08:00 (got: $value)"
}

# ---------------------------------------------------------------- nodes

# "headscale nodes ..." muscle memory: accept hs node <verb> as a two-word
# spelling of hs <verb>. Before this existed, "node" was an alias of "ls" and
# hs node rm gw read the *verb* as a user name ("failed to list nodes
# (user: rm): user not found").
cmd_node() {
	local sub=${1:-ls}
	(($#)) && shift
	case $sub in
		ls | list) cmd_ls "$@" ;;
		show | info | get) cmd_show "$@" ;;
		rm | del | delete | remove) cmd_rm "$@" ;;
		rename | mv | name) cmd_rename "$@" ;;
		tag | tags) cmd_tag "$@" ;;
		expire | logout | reauth) cmd_expire "$@" ;;
		route | routes) cmd_route "$@" ;;
		*)
			die "unknown node subcommand: $sub (available: ls, show, rm, rename, tag, expire, route;" \
				"to filter by user use: hs ls <user>)"
			;;
	esac
}

cmd_ls() {
	(($# <= 1)) || die "usage: hs ls [user]"
	load_nodes "${1:-}"
	if ((JSON)); then
		printf '%s\n' "$NODES_JSON"
		return 0
	fi
	jq -r "$JQ_LIB"'
		["ID", "NAME", "USER", "ADDRESS", "ONLINE", "LAST SEEN", "EXPIRY", "TAGS"],
		( .[]
		  | [
			  (.id | tostring),
			  (.given_name // .name // "-"),
			  (.user.name // "-"),
			  ((.ip_addresses // []) | csl),
			  (if .online then "online" else "offline" end),
			  (.last_seen.seconds | ts),
			  (.expiry.seconds | ts),
			  ((.tags // []) | csl)
			] )
		| @tsv' <<<"$NODES_JSON" | render_table
}

cmd_show() {
	(($# <= 1)) || die "usage: hs show <node>"
	local id name
	ensure_nodes
	id=$(resolve_node "${1:-}")
	if ((JSON)); then
		jq --argjson id "$id" '.[] | select(.id == $id)' <<<"$NODES_JSON"
		return 0
	fi
	name=$(node_display_name "$id")
	jq -r --argjson id "$id" --arg name "$name" "$JQ_LIB"'
		( .[] | select(.id == $id) ) as $n
		| "ID          \($n.id)",
		  "name        \($n.given_name // $name)",
		  "hostname    \($n.name // "-")",
		  "user        \($n.user.name // "-")",
		  "address     \($n.ip_addresses | lst)",
		  "online      \(if $n.online then "yes" else "no" end)",
		  "last seen   \($n.last_seen.seconds | ts)",
		  "expiry      \($n.expiry.seconds | ts)",
		  "tags        \($n.tags | lst)",
		  "approved    \($n.approved_routes | lst)",
		  "available   \($n.available_routes | lst)",
		  "serving     \($n.subnet_routes | lst)"' <<<"$NODES_JSON"
}

cmd_rm() {
	local force=0
	local -a targets=()
	while (($#)); do
		case $1 in
			-f | --force) force=1 ;;
			-*) die "unknown option: $1" ;;
			*) targets+=("$1") ;;
		esac
		shift
	done
	((${#targets[@]})) || die "missing node argument"

	local t id name
	ensure_nodes
	for t in "${targets[@]}"; do
		id=$(resolve_node "$t")
		name=$(node_display_name "$id")
		local -a args=(nodes delete -i "$id")
		((force)) && args+=(--force)
		if ((DRY_RUN)); then
			print_dry_run "${args[@]}"
			continue
		fi
		if ((force == 0)); then
			confirm "Delete node $name (ID $id)?" || {
				printf '%s: cancelled\n' "$PROG"
				return 0
			}
			# headscale asks its own question too (nodes delete has no way to
			# skip it except --force), and hs has just asked; without this the
			# user is prompted twice and a "no" at the second prompt still
			# makes hs print "deleted".
			args+=(--force)
		fi
		"$HEADSCALE_BIN" "${args[@]}" >/dev/null
		printf 'deleted %s (ID %s)\n' "$name" "$id"
	done
}

cmd_rename() {
	(($# == 2)) || die "usage: hs rename <node> <new-name>"
	local id
	ensure_nodes
	id=$(resolve_node "$1")
	if ((DRY_RUN)); then
		print_dry_run nodes rename -i "$id" "$2"
		return 0
	fi
	"$HEADSCALE_BIN" nodes rename -i "$id" "$2" >/dev/null
	printf 'renamed to %s\n' "$2"
}

cmd_tag() {
	(($# >= 1)) || die "usage: hs tag <node> <tag...>"
	local id
	ensure_nodes
	id=$(resolve_node "$1")
	shift
	(($#)) ||
		die "headscale v0.29 cannot remove all tags from a node; pass at least one tag (e.g. tag:mobile)"
	local -a args=(nodes tag -i "$id")
	local t
	for t in "$@"; do args+=(-t "$t"); done
	if ((DRY_RUN)); then
		print_dry_run "${args[@]}"
		return 0
	fi
	"$HEADSCALE_BIN" "${args[@]}" >/dev/null
	printf 'tags set to: %s\n' "$*"
}

cmd_expire() {
	(($# >= 1)) || die "usage: hs expire <node> [--at RFC3339] [--disable]"
	local target=$1
	shift

	local disable=0 at="" at_set=0
	while (($#)); do
		case $1 in
			-d | --disable) disable=1 ;;
			--at | -e)
				shift
				[[ $# -gt 0 ]] || die "--at needs a timestamp (RFC3339)"
				at=$1
				at_set=1
				;;
			*) die "unknown option: $1" ;;
		esac
		shift
	done

	if ((at_set)); then
		validate_rfc3339 "$at"
	fi

	local id
	ensure_nodes
	id=$(resolve_node "$target")

	if ((disable)); then
		if ((DRY_RUN)); then
			print_dry_run nodes expire -i "$id" --disable
			return 0
		fi
		"$HEADSCALE_BIN" nodes expire -i "$id" --disable >/dev/null
		printf 'expiry disabled (%s)\n' "$target"
		return 0
	fi

	local -a args=(nodes expire -i "$id")
	((at_set)) && args+=(-e "$at")
	if ((DRY_RUN)); then
		print_dry_run "${args[@]}"
		return 0
	fi
	"$HEADSCALE_BIN" "${args[@]}" >/dev/null
	if ((at_set)); then
		printf 'expiry set to %s (%s)\n' "$at" "$target"
	else
		printf 'logged out %s, it has to re-authenticate\n' "$target"
	fi
}

# ---------------------------------------------------------------- routes

cmd_route() {
	local sub=${1:-ls}
	case $sub in
		add)
			shift
			route_add "$@"
			;;
		rm | del | remove)
			shift
			route_rm "$@"
			;;
		ls | list | "") route_list "${2:-}" ;;
		*) route_list "$sub" ;;
	esac
}

route_list() {
	local filter=${1:-}
	ensure_nodes
	local id=""
	[[ -n $filter ]] && id=$(resolve_node "$filter")

	if ((JSON)); then
		# Always an array, even for a single node, so the shape never changes.
		jq --arg id "$id" '
			[ .[] | select($id == "" or (.id | tostring) == $id)
			  | select(((.approved_routes // []) | length) > 0
				  or ((.available_routes // []) | length) > 0
				  or ((.subnet_routes // []) | length) > 0)
			]' <<<"$NODES_JSON"
		return 0
	fi

	jq -r --arg id "$id" "$JQ_LIB"'
		["ID", "NAME", "APPROVED", "AVAILABLE", "SERVING"],
		( .[]
		  | select($id == "" or (.id | tostring) == $id)
		  | select(((.approved_routes // []) | length) > 0
			  or ((.available_routes // []) | length) > 0
			  or ((.subnet_routes // []) | length) > 0)
		  | [
			  (.id | tostring),
			  (.given_name // .name // "-"),
			  (((.approved_routes // []) | join(",")) | if . == "" then "-" else . end),
			  (((.available_routes // []) | join(",")) | if . == "" then "-" else . end),
			  (((.subnet_routes // []) | join(",")) | if . == "" then "-" else . end)
			] )
		| @tsv' <<<"$NODES_JSON" | render_table
}

route_add() {
	(($# >= 2)) || die "usage: hs route add <node> <cidr...>"
	local id
	ensure_nodes
	id=$(resolve_node "$1")
	shift

	local current merged
	current=$(approved_routes_of "$id")
	merged=$(jq -rn \
		--arg cur "$current" \
		--arg add "$(printf '%s\n' "$@")" '
		($cur | split(",") | map(select(. != ""))) as $c
		| ($add | split("\n") | map(select(. != ""))) as $a
		| (($c + $a) | unique | join(","))')

	if ((DRY_RUN)); then
		print_dry_run nodes approve-routes -i "$id" -r "$merged"
		return 0
	fi
	"$HEADSCALE_BIN" nodes approve-routes -i "$id" -r "$merged" >/dev/null
	printf 'approved routes: %s\n' "$merged"
}

route_rm() {
	(($# >= 1)) || die "usage: hs route rm <node> [cidr...]"
	local id
	ensure_nodes
	id=$(resolve_node "$1")
	shift

	if (($# == 0)); then
		if ((DRY_RUN)); then
			print_dry_run nodes approve-routes -i "$id" -r ""
			return 0
		fi
		"$HEADSCALE_BIN" nodes approve-routes -i "$id" -r "" >/dev/null
		printf 'all approved routes removed\n'
		return 0
	fi

	local current remaining
	current=$(approved_routes_of "$id")
	remaining=$(jq -rn \
		--arg cur "$current" \
		--arg del "$(printf '%s\n' "$@")" '
		($cur | split(",") | map(select(. != ""))) as $c
		| ($del | split("\n") | map(select(. != ""))) as $d
		| (($c - $d) | join(","))')

	if ((DRY_RUN)); then
		print_dry_run nodes approve-routes -i "$id" -r "$remaining"
		return 0
	fi
	"$HEADSCALE_BIN" nodes approve-routes -i "$id" -r "$remaining" >/dev/null
	printf 'approved routes: %s\n' "${remaining:-(none)}"
}

# ---------------------------------------------------------------- pre-auth keys

cmd_key() {
	local sub=${1:-ls}
	(($#)) && shift
	case $sub in
		new | create | add) key_new "$@" ;;
		ls | list) key_ls ;;
		rm | del | delete) key_action delete "$@" ;;
		expire | revoke) key_action expire "$@" ;;
		*) die "unknown key subcommand: $sub (available: new, ls, rm, expire)" ;;
	esac
}

key_new() {
	local user="" exp="1h" reusable=0 ephemeral=0
	local -a tags=()
	while (($#)); do
		case $1 in
			-u | --user)
				shift
				[[ $# -gt 0 ]] || die "-u needs a user name"
				user=$1
				;;
			-e | --expiration)
				shift
				[[ $# -gt 0 ]] || die "-e needs a duration (e.g. 30m, 24h)"
				exp=$1
				[[ -n $exp ]] || die "-e needs a duration (e.g. 30m, 24h)"
				;;
			-r | --reusable) reusable=1 ;;
			-E | --ephemeral) ephemeral=1 ;;
			-t | --tag)
				shift
				[[ $# -gt 0 ]] || die "-t needs a tag"
				tags+=("$1")
				;;
			*) die "unknown option: $1" ;;
		esac
		shift
	done

	local uid
	uid=$(resolve_user "$user")

	local -a args=(preauthkeys create -u "$uid" -e "$exp")
	((reusable)) && args+=(--reusable)
	((ephemeral)) && args+=(--ephemeral)
	local t
	for t in "${tags[@]}"; do args+=(--tags "$t"); done

	# Only the key itself goes to stdout so it can be piped.
	if ((DRY_RUN)); then
		print_dry_run "${args[@]}"
		return 0
	fi
	"$HEADSCALE_BIN" "${args[@]}"
}

key_ls() {
	local json
	json=$("$HEADSCALE_BIN" preauthkeys list -o json) || die "failed to list keys"
	json=$(as_list "$json")
	if ((JSON)); then
		printf '%s\n' "$json"
		return 0
	fi
	jq -r "$JQ_LIB"'
		["ID", "KEY", "REUSABLE", "EPHEMERAL", "USED", "EXPIRY", "OWNER"],
		( .[]
		  | [
			  (.id | tostring),
			  (.key // "-"),
			  (if .reusable then "yes" else "no" end),
			  (if .ephemeral then "yes" else "no" end),
			  (if .used then "yes" else "no" end),
			  (.expiration.seconds | ts),
			  (if ((.acl_tags // []) | length) > 0 then ((.acl_tags // []) | join(","))
			   elif .user.name then .user.name else "-" end)
			] )
		| @tsv' <<<"$json" | render_table
}

key_action() {
	local action=$1 label word
	shift
	if [[ $action == delete ]]; then
		label=deleted
		word='rm'
	else
		label=expired
		word='expire'
	fi
	(($#)) || die "usage: hs key $word <id...>"
	local id
	for id in "$@"; do
		[[ $id =~ ^[0-9]+$ ]] || die "key ID must be numeric: $id"
		((id > 0)) || die "key ID must be 1 or greater: $id"
		if ((DRY_RUN)); then
			print_dry_run preauthkeys "$action" -i "$id"
			continue
		fi
		"$HEADSCALE_BIN" preauthkeys "$action" -i "$id" >/dev/null
		printf 'key %s: %s\n' "$id" "$label"
	done
}

# ---------------------------------------------------------------- users

cmd_user() {
	local sub=${1:-ls}
	(($#)) && shift
	case $sub in
		ls | list) user_ls ;;
		new | create | add) user_new "$@" ;;
		rm | del | delete | destroy) user_rm "$@" ;;
		*) die "unknown user subcommand: $sub (available: ls, new, rm)" ;;
	esac
}

user_ls() {
	local json
	json=$("$HEADSCALE_BIN" users list -o json) || die "failed to list users"
	json=$(as_list "$json")
	if ((JSON)); then
		printf '%s\n' "$json"
		return 0
	fi
	jq -r "$JQ_LIB"'
		["ID", "NAME", "DISPLAY", "EMAIL", "CREATED"],
		( .[]
		  | [
			  (.id | tostring),
			  (.name // "-"),
			  (((.display_name // "")) | if . == "" then "-" else . end),
			  (((.email // "")) | if . == "" then "-" else . end),
			  (.created_at.seconds | ts)
			] )
		| @tsv' <<<"$json" | render_table
}

user_new() {
	(($# == 1)) || die "usage: hs user new <name>"
	if ((DRY_RUN)); then
		print_dry_run users create "$1"
		return 0
	fi
	"$HEADSCALE_BIN" users create "$1" >/dev/null
	printf 'created user %s\n' "$1"
}

user_rm() {
	local force=0
	local -a targets=()
	while (($#)); do
		case $1 in
			-f | --force) force=1 ;;
			-*) die "unknown option: $1" ;;
			*) targets+=("$1") ;;
		esac
		shift
	done
	((${#targets[@]})) || die "usage: hs user rm <name|id> [--force]"

	local t
	for t in "${targets[@]}"; do
		local -a args=(users destroy)
		if [[ $t =~ ^[0-9]+$ ]]; then
			((t > 0)) || die "user ID must be 1 or greater: $t"
			args+=(--identifier "$t")
		else
			args+=(--name "$t")
		fi
		((force)) && args+=(--force)
		if ((DRY_RUN)); then
			print_dry_run "${args[@]}"
			continue
		fi
		if ((force == 0)); then
			confirm "Delete user $t and all of its preauthkeys?" || {
				printf '%s: cancelled\n' "$PROG"
				return 0
			}
			# Same as nodes delete: headscale's own confirmation would prompt a
			# second time, so it is skipped once hs has asked.
			args+=(--force)
		fi
		"$HEADSCALE_BIN" "${args[@]}" >/dev/null
		printf 'deleted user %s\n' "$t"
	done
}

# ---------------------------------------------------------------- entrypoint

# version prints what headscale prints. --json wraps the same text: `version`
# is the bare version string parsed out of it and `raw` keeps the original
# lines, because headscale's own version output is not JSON and inventing a
# schema for commit/build time would break on the next release.
cmd_version() {
	local raw first
	raw=$("$HEADSCALE_BIN" version) || exit $?
	if ((JSON)); then
		first=${raw%%$'\n'*}
		jq -n --arg raw "$raw" --arg first "$first" '
			{version: (try ($first | capture("version[ ]+(?<v>[^ ]+)").v) catch null),
			 raw: $raw}'
		return 0
	fi
	printf '%s\n' "$raw"
}

main() {
	# Global flags may appear anywhere before the command's own arguments.
	# They are stripped here so every subcommand keeps its existing parser,
	# and a value that happens to be called --json is not a supported case.
	local -a passed=()
	while (($#)); do
		case $1 in
			--json) JSON=1 ;;
			--dry-run) DRY_RUN=1 ;;
			*) passed+=("$1") ;;
		esac
		shift
	done
	set -- ${passed[@]+"${passed[@]}"}

	local cmd=${1:-ls}
	(($#)) && shift

	# Help must work even where jq or headscale is missing or broken.
	case $cmd in help | -h | --help)
		usage
		return 0
		;;
	esac

	require_deps

	case $cmd in
		ls | list) cmd_ls "$@" ;;
		node | nodes) cmd_node "$@" ;;
		show | info) cmd_show "$@" ;;
		rm | del | delete) cmd_rm "$@" ;;
		rename | mv) cmd_rename "$@" ;;
		tag | tags) cmd_tag "$@" ;;
		expire | logout) cmd_expire "$@" ;;
		route | routes) cmd_route "$@" ;;
		key | keys | preauthkey | authkey) cmd_key "$@" ;;
		user | users) cmd_user "$@" ;;
		version) cmd_version ;;
		*) die "unknown command: $cmd (try hs help)" ;;
	esac
}

main "$@"
