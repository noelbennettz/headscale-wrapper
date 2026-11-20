# Security policy and limitations

`hs` is a small wrapper: it runs the local `headscale` CLI and formats its JSON.
It has no daemon, opens no socket, keeps no state, has no authentication of its
own and adds no privileges. Almost everything below follows from that.

## Reporting a problem

Open a **private security advisory** on this repository (Security → Advisories →
"Report a vulnerability"). Please do not open a public issue for anything that
would let someone run commands or read data they should not. There is no other
private channel and no bug bounty.

## It is a root tool, on purpose

`headscale` itself needs root (or membership of the group that owns its socket),
so `hs` is meant to be run as root on the headscale server. Consequences:

- **No privilege separation.** `hs` does not drop privileges, does not re-exec
  through `sudo`, and does not restrict what the wrapped `headscale` binary may
  do. Whatever headscale can do to the network, `hs` can do — `hs rm` deletes
  nodes, `hs user rm` destroys a user *and its preauthkeys*.
- **Do not hand it to unprivileged users.** No `sudoers` entry, no setuid
  wrapper, no "read-only" mode. `hs ls --json` is safe to look at, but the same
  binary running as root also accepts `hs rm`. The confirmation prompt and the
  refusal to prompt in a non-interactive shell are guard rails against
  accidents, not an access-control boundary; `--force` and `--dry-run` exist
  precisely to skip the prompt.
- **Environment variables are input.** `HS_HEADSCALE_BIN` decides which binary
  gets executed. If `hs` runs as root from `sudo`, a script or a CI job, do not
  pass that variable through from an untrusted source (`env_keep`, a
  user-controlled unit file, an inherited shell). The same applies to
  `HS_DEFAULT_USER`, which selects the user a new preauthkey is issued for.
- **`--dry-run` output is text, not a command to evaluate.** It is shell-quoted
  so you can read and copy it, but only feed it to a shell yourself, from
  arguments you control.
- **`hs key new` prints a credential** — the preauthkey, alone on stdout so it
  can be captured. Do not pipe it into a log, a shell history file or a bug
  report. `hs` does not mask it and has no side channel for it.

## Coupled to one headscale major version

`hs` parses headscale's `--output json` by field name (`given_name`,
`approved_routes`, `ip_addresses`, `expiration.seconds`, ...) and builds
headscale's command line. Only **headscale v0.29** is verified: CI runs the
integration test against two pinned v0.29 images (`v0.29.0` and the latest
`v0.29.x` at the time the row was added).

A headscale upgrade that renames or reshapes a field does not fail loudly — the
column it fed simply prints `-`, which is why the pinned matrix and
`./test/integration.sh` matter. Treat a new headscale minor as unverified until
the matrix gains a row and the JSON is re-checked; nothing in `hs` detects the
server version at runtime.

## Other limits worth knowing

- Node, user and tag arguments reach `headscale` as separate `argv` entries and
  are never evaluated by a shell inside `hs`; the one place values are
  interpolated is `jq --arg`. A name that begins with `-` is passed through
  without an inserted `--`, so headscale may read it as a flag — use the ID.
- CIDRs, tags and expiry timestamps are **not validated** except for the RFC3339
  *shape* of `hs expire --at`; headscale decides what they mean.
- `hs` writes nothing but whatever headscale writes. It does create one
  temporary file (`mktemp` under `TMPDIR`) to capture a failed `nodes list`'s
  stderr; it contains headscale's error text, no credentials, and is deleted
  immediately.
- The release workflow's build-provenance attestation covers the release assets,
  not a copy you edited yourself. `SHA256SUMS` covers the three scripts only.
- Documentation is written for the default single-server setup: root on the
  headscale host, `headscale` CLI on `PATH`, `jq` installed. Pointing
  `HS_HEADSCALE_BIN` at a wrapper that reaches a remote server works in
  principle but is untested here; the CLI still has to authenticate to that
  server, which is outside what `hs` knows about.
