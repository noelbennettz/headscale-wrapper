#!/usr/bin/env bash
# Integration test: run hs against a real headscale server in Docker.
#
# The point is to cover what the fake headscale cannot: the shape of the JSON
# that real headscale emits, the error text it returns, and the commands hs
# builds for a node that really exists. Nothing is installed on the host and no
# host port is used — hs talks to the server through `docker exec`, and the
# Tailscale client that registers a node joins the same Docker network.
#
# Everything is read-only: the only write commands exercised are the ones the
# client needs to register, plus `--dry-run` for the rest.
#
# Run with: ./test/integration.sh
# Env:
#   HS_IT_IMAGE     headscale image (default: the digest CI pins)
#   HS_IT_TS_IMAGE  Tailscale client image
#   HS_IT_KEEP=1    keep the containers and the work directory for debugging
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hs=$here/hs

# Pinned by digest: nothing here should change under us between runs.
HEADSCALE_IMAGE=${HS_IT_IMAGE:-ghcr.io/juanfont/headscale@sha256:5d464c7ba8f5b2c1472f926fae4cd67f136d66ec108c0b4ad1891856ac6da915}
TAILSCALE_IMAGE=${HS_IT_TS_IMAGE:-tailscale/tailscale@sha256:72c1e19e0aedca96b8533bbb0b4368564410ff20b17e53b804eb6c1f04a31be4}

suffix=$$
network=hs-it-net-$suffix
server=hs-it-server-$suffix
client=hs-it-client-$suffix
work=$(mktemp -d)

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
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

check_not_contains() {
	local name=$1 want=$2 got=$3
	if [[ $got == *"$want"* ]]; then ng "$name" "without $want" "$got"; else ok "$name"; fi
}

check_status() {
	local name=$1 want=$2 got=$3
	if [[ $got == "$want" ]]; then ok "$name"; else ng "$name" "exit=$want" "exit=$got"; fi
}

check_json() {
	local name=$1 filter=$2 json=$3
	if jq -e "$filter" <<<"$json" >/dev/null 2>&1; then
		ok "$name"
	else
		ng "$name" "$filter" "$json"
	fi
}

cleanup() {
	if [[ ${HS_IT_KEEP:-0} == 1 ]]; then
		printf 'kept: containers %s and %s, work dir %s\n' "$server" "$client" "$work"
		return
	fi
	docker rm -f "$client" "$server" >/dev/null 2>&1 || true
	docker network rm "$network" >/dev/null 2>&1 || true
	rm -rf "$work"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
	printf 'integration: docker is required for this test\n' >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	printf 'integration: jq is required for this test\n' >&2
	exit 1
}

mkdir -p "$work/data"
chmod 0777 "$work/data"

# A server that needs no host network, no TLS and no external DERP map: the
# embedded DERP server with its own key is enough for a single node.
cat >"$work/config.yaml" <<'EOF'
server_url: http://headscale:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 0.0.0.0:50443
grpc_allow_insecure: true
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
derp:
  server:
    enabled: true
    private_key_path: /var/lib/headscale/derp_private.key
    region_id: 999
    region_code: local
    region_name: local
    stun_listen_addr: 0.0.0.0:3478
dns:
  magic_dns: false
  override_local_dns: false
  nameservers:
    global: ["1.1.1.1"]
unix_socket: /var/lib/headscale/headscale.sock
unix_socket_permission: "0770"
log:
  level: warn
EOF

docker image inspect "$HEADSCALE_IMAGE" >/dev/null 2>&1 || docker pull "$HEADSCALE_IMAGE" >/dev/null ||
	{ printf 'integration: cannot obtain %s\n' "$HEADSCALE_IMAGE" >&2; exit 1; }
binary=$(docker image inspect "$HEADSCALE_IMAGE" --format '{{index .Config.Entrypoint 0}}')
[[ -n $binary ]] || { printf 'integration: %s has no entrypoint\n' "$HEADSCALE_IMAGE" >&2; exit 1; }

# hs runs on the host; this wrapper is its "headscale binary". It is what makes
# the whole thing a real test: hs builds the argv, real headscale answers.
cat >"$work/headscale-cli" <<EOF
#!/usr/bin/env bash
exec docker exec -i $server $binary --config /etc/headscale/config.yaml "\$@"
EOF
chmod +x "$work/headscale-cli"
export HS_HEADSCALE_BIN=$work/headscale-cli

docker network create "$network" >/dev/null || exit 1
docker run -d --name "$server" --network "$network" --network-alias headscale \
	-v "$work/data:/var/lib/headscale" \
	-v "$work/config.yaml:/etc/headscale/config.yaml:ro" \
	"$HEADSCALE_IMAGE" --config /etc/headscale/config.yaml serve >/dev/null || exit 1

# Wait for the gRPC API instead of a fixed sleep.
ready=0
for _ in $(seq 1 60); do
	if "$HS_HEADSCALE_BIN" users list -o json >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 2
done
if ((ready == 0)); then
	printf 'integration: headscale did not start\n' >&2
	docker logs "$server" >&2 || true
	exit 1
fi

printf 'headscale %s, image %s\n' "$("$hs" version | head -1)" "$HEADSCALE_IMAGE"

# ---------------------------------------------------------------- users and keys

out=$("$hs" user new alice 2>&1)
check_status "user new: exits 0" 0 $?
check_contains "user new: confirms" "created user alice" "$out"

out=$("$hs" user ls)
check_contains "user ls: lists the real user" "alice" "$out"

out=$("$hs" user ls --json)
check_json "user ls --json: real JSON" 'length == 1 and .[0].name == "alice"' "$out"

key=$("$hs" key new -u alice -e 1h)
check_status "key new: exits 0" 0 $?
check_contains "key new: prints only a preauthkey" "hskey-auth-" "$key"

out=$("$hs" key ls)
check_contains "key ls: lists the new key" "hskey-auth-" "$out"

out=$("$hs" key ls --json)
check_json "key ls --json: real JSON" 'length == 1 and .[0].user.name == "alice"' "$out"

out=$("$hs" version --json)
check_json "version --json: parses the real version" '.version | startswith("v0.29.")' "$out"

# ---------------------------------------------------------------- a real node

docker pull "$TAILSCALE_IMAGE" >/dev/null 2>&1 || true
docker run -d --name "$client" --network "$network" \
	--entrypoint tailscaled "$TAILSCALE_IMAGE" \
	--tun=userspace-networking --state=/tmp/tailscaled.state >/dev/null || exit 1

joined=0
for _ in $(seq 1 30); do
	if docker exec "$client" tailscale up --login-server=http://headscale:8080 \
		--authkey="$key" --hostname=it-node --accept-routes=false >/dev/null 2>&1; then
		joined=1
		break
	fi
	sleep 2
done
if ((joined == 0)); then
	printf 'integration: the tailscale client did not join\n' >&2
	docker logs "$client" >&2 || true
	exit 1
fi

node=0
for _ in $(seq 1 45); do
	if "$hs" ls --json 2>/dev/null | jq -e 'length >= 1' >/dev/null 2>&1; then
		node=1
		break
	fi
	sleep 2
done
if ((node == 0)); then
	printf 'integration: the node never appeared in headscale\n' >&2
	exit 1
fi

# ---------------------------------------------------------------- read commands

out=$("$hs" ls)
check_contains "ls: header" "NAME" "$out"
check_contains "ls: real node name" "it-node" "$out"
check_contains "ls: real user" "alice" "$out"
check_contains "ls: assigned address" "100.64.0." "$out"
if [[ $(grep -c '^1 ' <<<"$out") == 1 ]]; then
	ok "ls: one row for the node"
else
	ng "ls: one row for the node" "" "$out"
fi

out=$("$hs" ls --json)
check_json "ls --json: headscale fields" \
	'length == 1 and .[0].given_name == "it-node" and (.[0].ip_addresses | length) >= 1' "$out"

out=$("$hs" show it-node)
check_contains "show: resolves the name to the ID" "ID          1" "$out"
check_contains "show: user from the server" "user        alice" "$out"
check_contains "show: address assigned by the server" "address     100.64.0." "$out"
check_contains "show: no routes on a fresh node" "approved    -" "$out"

out=$("$hs" show it-node --json)
check_json "show --json: real node object" \
	'.id == 1 and .given_name == "it-node" and .user.name == "alice"' "$out"

out=$("$hs" route)
check_contains "route: header" "APPROVED" "$out"
if [[ $(wc -l <<<"$out") == 1 ]]; then
	ok "route: no route rows for a fresh node"
else
	ng "route: no route rows for a fresh node" "1 line" "$out"
fi

out=$("$hs" route it-node)
check_contains "route <node>: header" "SERVING" "$out"

out=$("$hs" route it-node --json)
check_json "route --json: empty array for a fresh node" 'length == 0' "$out"

# ---------------------------------------------------------------- write paths

out=$("$hs" expire it-node --at 2030-01-01T00:00:00Z --dry-run)
check_contains "dry-run: expire builds the real command" \
	"nodes expire -i 1 -e 2030-01-01T00:00:00Z" "$out"
out=$("$hs" show it-node)
check_contains "dry-run: the expiry was not changed" "expiry      -" "$out"

out=$("$hs" rm it-node --dry-run)
check_contains "dry-run: rm builds the real command" "nodes delete -i 1" "$out"
out=$("$hs" show it-node 2>&1)
check_status "dry-run: the node still exists" 0 $?

out=$("$hs" tag it-node tag:integration --dry-run)
check_contains "dry-run: tag builds the real command" "nodes tag -i 1 -t tag:integration" "$out"
out=$("$hs" show it-node)
check_contains "dry-run: the tags were not changed" "tags        -" "$out"

# ---------------------------------------------------------------- error paths

out=$("$hs" show nosuchnode 2>&1)
check_status "unknown node: exits 1" 1 $?
check_contains "unknown node: message" "no such node: nosuchnode" "$out"

out=$("$hs" ls nosuchuser 2>&1)
check_status "unknown user: exits 1" 1 $?
check_contains "unknown user: keeps headscale's reason" "user not found" "$out"
check_not_contains "unknown user: no gRPC noise" "desc = " "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
