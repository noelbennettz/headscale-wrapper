# hs — reference

> Applies to `v1.1.0` and the headscale v0.29 CLI. An older release keeps its
> documentation in the `README.md` and `DOCS.md` of that release's tag on
> GitHub; this tree only documents the current one.

Everything that is not part of the skeleton in [README.md](README.md): the full
command reference, output, exit codes, environment variables, FAQ, tests, the
mapping to the native `headscale` CLI and the parsing assumptions.

## Contents

- [Features](#features)
- [Install, update, uninstall](#install-update-uninstall)
- [Command reference](#command-reference)
- [Naming nodes](#naming-nodes)
- [When headscale fails](#when-headscale-fails)
- [Dates, durations and numbers](#dates-durations-and-numbers)
- [Tags](#tags)
- [Sample output](#sample-output)
- [JSON output](#json-output)
- [Dry runs](#dry-runs)
- [Exit codes](#exit-codes)
- [Environment variables](#environment-variables)
- [FAQ](#faq)
- [Tests](#tests)
- [Mapping to the native CLI](#mapping-to-the-native-cli)
- [Implementation notes](#implementation-notes)

## Features

- **Node commands by name or ID**: `hs ls [user]`, `hs show`, `hs rm`,
  `hs rename`, `hs tag`, `hs expire` — a node is found by `given_name`, then
  `hostname`, then a unique prefix
- **`hs node <verb> ...`** — the headscale-style two-word spelling (`hs node rm
  gw-fmt-1` = `hs rm gw-fmt-1`), so muscle memory from the native CLI works and
  an unknown verb is an error rather than a user filter
- **Ambiguity is an error, never a guess**: `hs show lap` lists the candidates
  and asks for the ID instead of picking one
- **Subnet routes that keep the approved list**: `hs route add` reads the
  existing routes and sends the merged list, because headscale's
  `approve-routes` replaces it; `hs route rm` with no CIDR withdraws all
- **Preauthkeys in one line**: `hs key new` writes no text of its own — headscale
  prints the key alone — so `KEY=$(hs key new -u alice -e 24h)` captures exactly
  the key
- **Errors keep headscale's reason**: the `rpc error: ... desc = ` noise is
  dropped, so `hs ls rm` says `user not found` and not just `failed`
- **Safe by default**: `hs rm` and `hs user rm` ask first and refuse to run in a
  non-interactive shell (pipe, cron) unless `--force` is given; `--dry-run`
  prints the `headscale` command instead of running it, without a prompt
- **Stable output for pipelines**: columns aligned by `column` when it exists
  and by an internal `awk` fallback when it does not; trailing whitespace is
  stripped, timestamps are UTC, empty values are `-`
- **IPv4, IPv6 and single-stack hosts**: node addresses are printed exactly as
  headscale reports them — IPv4-only, IPv6-only or both, `-` when none are
  assigned — and subnet routes accept `fd00::/64` as readily as `10.0.0.0/8`;
  `hs` opens no socket and resolves no name of its own, so it runs unchanged on
  IPv4-only, IPv6-only and dual-stack machines
- **`--json` on the read commands**: `hs ls --json`, `hs show`, `hs route`,
  `hs key ls`, `hs user ls` and `hs version` print headscale's JSON instead of a
  table, unchanged, so scripts can use the same name resolution and get the raw
  fields
- **No state of its own**: reads and writes both go through the same `headscale`
  binary; two runtime environment variables, no daemon and no config file

## Install, update, uninstall

`column` from util-linux is optional (there is an `awk` fallback). `jq` is a
hard requirement: without it `hs` prints a hint and exits instead of failing
halfway through.

```
hs: jq not found. Install it first (Debian/Ubuntu: apt-get install -y jq, RHEL family: dnf install -y jq)
```

Install as root for the default path:

```sh
./install.sh                 # copies to /usr/local/bin/hs (default)
./install.sh /usr/bin/hs     # or pick the exact path
./install.sh --prefix /opt/hs   # or a prefix: /opt/hs/bin/hs
```

You can also run it straight from the checkout, without installing:

```sh
HS_HEADSCALE_BIN=/usr/local/bin/headscale ./hs ls
```

Without root, install under a prefix you own — `--prefix` is the same knob for
`install.sh` and `uninstall.sh`, and it is the only form that creates a
directory (`PREFIX/bin`):

```sh
./install.sh --prefix "$HOME/.local"      # ~/.local/bin/hs
./uninstall.sh --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"      # if it is not in PATH already
```

Check the install: `command -v hs` prints the path it went to, `hs help` prints
the command list without touching `headscale`, and `hs ls` prints the node table
(or `no nodes` on a fresh server). A `command not found` after installing to a
custom path means that directory is not in `PATH`; the installer says so
(`note: <dir> is not in PATH`) and warns when a different `hs` would win.

The installer checks that the destination directory exists and is writable by
you before touching anything, and its failure messages say which of the three
ways out applies: run it with `sudo`, create the missing directory, or use
`--prefix`. It warns when `jq` or `headscale` is missing but does not fail on
it. Apart from `--prefix` creating `PREFIX/bin`, it creates no directory,
inspects nothing that is already there and replaces the one destination file.
To update, pull and install again — `install.sh` overwrites the script in place,
so there is no state to migrate and nothing else on the machine changes:

```sh
git pull
./install.sh                 # same path as the first install
```

`hs version` prints the version of the headscale binary it talks to — that is
the number which matters for the JSON parsing, not `hs`'s own release.

Uninstall:

```sh
./uninstall.sh               # removes /usr/local/bin/hs
./uninstall.sh /usr/bin/hs   # if you installed it somewhere else
```

It refuses to delete a file that does not carry the `hs` header line (the
`name-based wrapper around the headscale` comment near the top); `--force` or
`-f` deletes such a file anyway, with a warning on stderr. It removes that one
file and nothing else: headscale, jq and the variables you exported yourself
(`HS_DEFAULT_USER` etc.) are untouched. Running it twice is fine — the second run
prints `not installed (nothing to do)` and exits 0 — and after a successful
removal it notes any other `hs` still on `PATH`.

Tested on Debian/Ubuntu with bash 5.x against headscale v0.29; nothing in the
script is Linux-specific beyond the usual coreutils.

## Releases and how to verify them

Pushing an annotated `vMAJOR.MINOR.PATCH` tag is the only release step, and it is
manual: the workflow runs on the tag, it never creates one.

`.github/workflows/release.yml` re-runs `bash -n`, ShellCheck, actionlint and the
smoke and documentation tests on the tagged tree, writes `SHA256SUMS` for `hs`,
`install.sh` and `uninstall.sh`, attests all four files with GitHub build
provenance (`actions/attest-build-provenance`), and attaches them to the GitHub
release for that tag (`gh release create --verify-tag`; re-running the workflow
for the same tag replaces the assets instead of failing). Nothing is signed with
a PGP or cosign key — the attestation is the signature: it is issued by GitHub
for this repository, this workflow and this tag.

Verify a download:

```sh
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify hs --repo noelbennettz/headscale-wrapper
```

The checksums catch a truncated or re-uploaded file; the attestation proves the
file came out of this repository's release workflow for that tag. Both are
optional — `hs` is a single bash script you can read before running.

## Command reference

| Command | Description |
| --- | --- |
| `hs` / `hs ls [user]` | List nodes (ID, name, user, addresses, online, last seen, expiry, tags) |
| `hs node <verb> ...` | The same node commands spelled headscale-style: `hs node rm gw-fmt-1` = `hs rm gw-fmt-1` |
| `hs show <node>` | Details for one node, including approved/available/serving routes |
| `hs rm <node...> [--force]` | Delete nodes, asks first |
| `hs rename <node> <new-name>` | Rename a node |
| `hs tag <node> <tag...>` | Overwrite tags; each tag must be `tag:lowercase` (see [Tags](#tags)) |
| `hs expire <node>` | Log out (forces re-authentication) |
| `hs expire <node> --at 2026-02-01T00:00:00Z` | Set an explicit expiry (RFC3339, see [Dates, durations and numbers](#dates-durations-and-numbers)) |
| `hs expire <node> --disable` | Disable expiry |
| `hs route [node]` | List nodes that have routes |
| `hs route add <node> <cidr...>` | Approve routes (**merged** with the existing ones) |
| `hs route rm <node> [cidr...]` | Withdraw routes; no cidr withdraws all |
| `hs key new [-u user] [-e 24h] [-r] [-E] [-t tag]` | Create a preauthkey (`-e` defaults to `1h`); stdout is the key only |
| `hs key ls` / `hs key rm <id...>` / `hs key expire <id...>` | List / delete / expire keys |
| `hs user ls` / `hs user new <name>` / `hs user rm <name\|id> [--force]` | User management |
| `hs version` / `hs help` | Version and help |

`hs expire` also accepts `-d`/`--disable`, and `-e` as an alias of `--at`;
`hs key new` accepts the long forms `--user`, `--expiration`, `--reusable`,
`--ephemeral` and `--tag`, and sends one `--tags` flag per `-t`. `-f` is the
short form of `--force`. The node, key, route and user groups accept the usual
verb aliases (`rm`/`del`/`delete`, `ls`/`list`, `expire`/`revoke`, ...), and the
top-level command names have aliases of their own (`nodes`, `info`, `mv`,
`tags`, `logout`, `keys`/`preauthkey`/`authkey`, `users`). `hs help`, `hs -h`
and `hs --help` run before the dependency check and work without `jq` or
`headscale`.

### `hs node <verb>` — headscale-style spelling

Node commands also accept the two-word spelling the native CLI uses: `hs node
ls`, `hs node show`, `hs node rm`, `hs node rename`, `hs node tag`, `hs node
expire` and `hs node route` run `hs ls`, `hs show`, `hs rm`, and so on; bare
`hs node` lists nodes. An unknown verb is an error rather than a user filter:

```
$ hs node frobnicate gw
hs: unknown node subcommand: frobnicate (available: ls, show, rm, rename, tag, expire, route; to filter by user use: hs ls <user>)
```

## Naming nodes

`<node>` accepts an ID or a name (matched against `given_name`, then
`hostname`). Names also match on a unique **prefix** — a name that only
contains the query does not match, so `hs show top` will not hit `laptop`. When
several nodes match, the candidates are listed and you are asked to use the ID:

```
$ hs show lap
hs: ambiguous node name: lap matches several (1:laptop, 3:laptop2), use the ID instead
```

## When headscale fails

`hs` keeps headscale's own explanation and drops the gRPC noise, so a wrong
user or a stopped server says why instead of just "failed":

```
$ hs ls rm
hs: failed to list nodes (user: rm): user not found (hs user ls lists the users)
```

## Dates, durations and numbers

`hs` passes these values to headscale instead of re-implementing the calendar
rules, so the formats and limits below are those of headscale v0.29. The one
value `hs` inspects itself is `--at`, where it checks the RFC3339 shape before
spawning anything. A value headscale rejects comes back as `parsing expiry
time: ...` or `parsing duration: ...` on stderr, with the exit status of the
`headscale` process.

### Expiry timestamps — `hs expire --at`

`--at` is a **point in time in RFC3339 form**: full date, time and a timezone
(`Z` or `±hh:mm`). It is not a duration and not a Unix timestamp. `hs` checks
that shape with a regular expression before calling headscale, so typos fail
fast with an `hs:` hint instead of a parse error from headscale:

| Input | Accepted | Why |
| --- | --- | --- |
| `2026-02-01T00:00:00Z` | yes | UTC |
| `2026-02-01T08:00:00+08:00` | yes | explicit offset |
| `2026-02-01T00:00:00.500Z` | yes | fractional seconds are allowed |
| `2026-02-01` | no | date only |
| `2026-02-01T00:00:00` | no | missing timezone |
| `2026-02-01 00:00:00Z` | no | space instead of `T` |
| `1767225600` | no | epoch seconds; use the expanded date/time |
| `24h`, `7d` | no | `--at` is a timestamp, not a duration |

A rejected value prints `hs: --at takes an RFC3339 timestamp with a timezone,
e.g. 2026-02-01T00:00:00Z or 2026-02-01T08:00:00+08:00 (got: <value>)`; an empty
one prints `hs: --at needs a timestamp, ...`. Neither reaches headscale.

What the timestamp means:

- no `--at` → the node expires **now** (it is logged out and has to
  re-authenticate);
- `--at` in the past → same as expiring now;
- `--at` in the future → the node keeps working until that moment, then drops
  off and has to re-authenticate;
- `--disable` → the expiry is removed entirely (the node never expires), and the
  `EXPIRY` column of `hs ls` shows `-`;
- `--disable` together with `--at` → `--disable` wins: the expiry is removed and
  `--at` is not sent, though its shape is still checked so a typo does not go
  unnoticed.

`hs ls` and `hs show` print timestamps in **UTC** (jq's `todate`), so a `+08:00`
expiry comes back shifted to the same instant in UTC. `hs expire` echoes the
`--at` value it was given, unchanged, in its confirmation line.

Note the letter clash: `-e` means *timestamp* in `hs expire` but *duration* in
`hs key new`. Same letter, different grammar:

```sh
hs expire phone --at 2026-02-01T00:00:00Z   # a point in time
hs key new -u alice -e 24h                 # 24 hours from now
```

### Preauthkey lifetime — `hs key new -e`

`-e` is a **duration counted from now**, parsed by headscale with Prometheus'
`model.ParseDuration`. Rules:

- units: `y` (365 d), `w` (7 d), `d` (24 h), `h`, `m`, `s`, `ms` — nothing else
  (`us`, `ns`, `M` for month are rejected);
- whole numbers only: `1.5h` is invalid, write `90m`;
- units must run from largest to smallest: `1d12h30m` is fine, `30m1d` is not;
- no negatives and no spaces;
- `0` is accepted but means "expires immediately", **not** "never expires";
- the default when `-e` is omitted is `1h` (headscale's own default);
- the upper bound is Go's `time.Duration`, about 292 years (`2562047h`); larger
  values fail with `duration out of range`.

```sh
hs key new -u alice            # expires in 1h
hs key new -u alice -e 30m     # half an hour to enroll the node
hs key new -u alice -e 7d -r   # one week, reusable
hs key new -u alice -e 8760h   # one year
```

Durations are the only way to get a long-lived key: there is no "forever"
preauthkey option, and `-e 0` hands you a key that is already expired.

### IDs

Node, user and preauthkey IDs are unsigned integers assigned by headscale and
count from **1**; `0` is treated as "unset" and can never be a valid ID.
`hs key rm` and `hs key expire` take plain decimal numbers only — anything else
fails with `key ID must be numeric: <value>`, and `0` is refused locally with
`... must be 1 or greater: 0` rather than being sent to headscale. `hs rm`,
`hs show`, `hs rename`, `hs tag` and `hs expire` take an ID *or* a name, and so
do `hs route`, `hs route add` and `hs route rm`; `hs user rm` treats an all-digit
argument as an ID and everything else as a name. In a node or user query an exact
ID wins over a name, so a node whose `given_name` is a number is reachable only
through a non-numeric spelling of its hostname.

## Tags

Tags come from headscale's ACL vocabulary and are checked by headscale, not by
`hs`: each one must start with `tag:` (so `tag:mobile`, not `mobile`), be
lowercase and contain no spaces. `hs tag <node> <tag...>` sends the whole list in
one `nodes tag` call, which replaces the node's tags, so a node ends up with
exactly the tags you name.

`hs tag <node>` with no tag argument fails before any request is sent, because
headscale v0.29 has no way to clear a node's tags:

```
$ hs tag phone
hs: headscale v0.29 cannot remove all tags from a node; pass at least one tag (e.g. tag:mobile)
```

## Sample output

```console
$ hs ls
ID  NAME     USER   ADDRESS                       ONLINE   LAST SEEN             EXPIRY                TAGS
1   laptop   alice  100.64.0.1,fd7a:115c:a1e0::1  online   2026-01-01T00:00:00Z  2027-01-15T08:00:00Z  -
2   phone    alice  100.64.0.2                    offline  2025-12-31T16:53:20Z  -                     tag:mobile
3   laptop2  bob    100.64.0.3                    online   2026-01-01T20:40:00Z  2023-11-14T22:13:20Z  -

$ hs show laptop
ID          1
name        laptop
hostname    laptop-hp
user        alice
address     100.64.0.1, fd7a:115c:a1e0::1
online      yes
last seen   2026-01-01T00:00:00Z
expiry      2027-01-15T08:00:00Z
tags        -
approved    192.168.1.0/24
available   192.168.1.0/24, 10.10.0.0/16
serving     192.168.1.0/24

$ hs route
ID  NAME    APPROVED        AVAILABLE                    SERVING
1   laptop  192.168.1.0/24  192.168.1.0/24,10.10.0.0/16  192.168.1.0/24

$ hs key ls
ID  KEY              REUSABLE  EPHEMERAL  USED  EXPIRY                OWNER
1   pk-aaaaaaaaaaaa  yes       no         no    2026-01-02T00:00:00Z  tag:mobile
2   pk-bbbbbbbbbbbb  no        yes        yes   2026-01-01T20:40:00Z  bob

$ hs user ls
ID  NAME   DISPLAY  EMAIL              CREATED
1   alice  Alice    alice@example.com  2025-12-29T09:20:00Z
2   bob    -        -                  2025-12-30T13:06:40Z
```

(The rows above come from `test/fixtures`, i.e. synthetic data.)

Column conventions: `NAME` is the node's `given_name`, falling back to its
hostname (in `hs show`, `name` is that same value and `hostname` is headscale's
`name`); `ADDRESS`, `TAGS`, `APPROVED` and the other route columns join multiple
values with a comma and show `-` when the list is empty; `EXPIRY` is `-` when the
node has no expiry; `OWNER` in `hs key ls` shows the key's ACL tags when it has
any and the user name otherwise; `DISPLAY`, `EMAIL` and `CREATED` fall back to
`-` for fields headscale leaves empty.

## JSON output

`--json` turns a read command into a JSON printer. It may come before or after
the command (`hs --json ls` and `hs ls --json` are the same) and it applies to
`hs ls`, `hs show`, `hs route`, `hs key ls`, `hs user ls` and `hs version`:

```console
$ hs ls --json
[
  {
    "id": 1,
    "machine_key": "mkey:abc123",
    ...
    "given_name": "laptop",
    "approved_routes": ["192.168.1.0/24"],
    "ip_addresses": ["100.64.0.1", "fd7a:115c:a1e0::1"]
  }
]

$ hs show laptop --json | jq -r .user.name
alice
```

What each one prints:

| Command | JSON |
| --- | --- |
| `hs ls [user] --json` | Headscale's `nodes list -o json`, byte for byte |
| `hs show <node> --json` | The one node object, resolved by name/ID/prefix like the table |
| `hs route [node] --json` | An array of the nodes the table would show — always an array, even for one node or none |
| `hs key ls --json` | Headscale's `preauthkeys list -o json`, byte for byte |
| `hs user ls --json` | Headscale's `users list -o json`, byte for byte |
| `hs version --json` | `{"version": "0.29.0", "raw": "<headscale version output>"}` |

`hs ls` and `hs route` are the only two that filter, and they filter the same
way with and without `--json`. The pass-through commands do not re-encode the
JSON, so the field names, ordering and key masking are exactly what headscale
emits; `--json` on `hs show` re-serialises the single object, which is the one
case where the layout comes from `jq`.

`hs version --json` is the exception that does not pass anything through:
headscale prints its version as text (`headscale version v0.29.0`, plus commit
and build time), so `hs` parses the version out of the first line and keeps the
original text in `raw` rather than promising a schema for fields headscale may
rename.

Write commands ignore `--json` — `hs key new` already prints only the key, and
the destructive commands print one line per action. Exit codes do not change:
`--json` never turns an error into an empty document, it fails the same way the
table would.

## Dry runs

`--dry-run` on a write command does everything except the write: it resolves the
node or user the same way, then prints the `headscale` command it would have run,
prefixed `dry-run: `, instead of running it. Nothing changes and no confirmation
prompt appears, so a destructive command can be inspected from a pipe, a cron
job or a review script without `--force`:

```console
$ hs rm phone --dry-run
dry-run: headscale nodes delete -i 2

$ hs route add laptop 10.0.0.0/8 --dry-run
dry-run: headscale nodes approve-routes -i 1 -r 10.0.0.0/8,192.168.1.0/24

$ hs key new -u alice -e 24h -r --dry-run
dry-run: headscale preauthkeys create -u 1 -e 24h --reusable
```

It covers `hs rm`, `hs rename`, `hs tag`, `hs expire` (both forms), `hs route
add`, `hs route rm`, `hs key new`, `hs key rm`, `hs key expire`, `hs user new`
and `hs user rm`, including the two-word `hs node <verb>` spelling. Some of
those commands are computed rather than copied — `hs route add` prints the
**merged** route list and `hs route rm` the remaining one — so the line shows
what would actually be sent, not what you typed.

Name resolution still reads: the ID in the printed line comes from a real
`nodes list` / `users list` call. A name that does not resolve, or one that is
ambiguous, fails with the same message and exit status as the real run — a dry
run never prints a command for a node it could not identify. Read commands
ignore `--dry-run` (they only read anyway), and `--dry-run` with `--json` is
redundant: `--json` applies to reads, `--dry-run` to writes.

The arguments are shell-quoted only where they have to be (`-r ''` for an empty
route list, `tag:with\ space` for a tag with a space), so the line can be copied
into a shell as is.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or the user declined a confirmation prompt (`hs` prints `cancelled` and returns 0) |
| 1 | Every error `hs` detects itself: missing jq or headscale, unknown command or node, ambiguous name, a failed `nodes list`/`users list`/`preauthkeys list`, a bad flag, a rejected ID, or the refusal to prompt in a non-interactive shell |
| *n* | Whatever the `headscale` or `jq` process returned, when it fails a command whose status `hs` does not check itself — e.g. `hs version`, `hs rm --force`, `hs key rm` |

## Environment variables

The first two are read at runtime by `hs` itself; the third only affects the
installer and uninstaller.

| Variable | Default | Description |
|---|---|---|
| `HS_HEADSCALE_BIN` | `headscale` | The headscale binary `hs` calls. A bare name is looked up in `PATH`, a path is used as given; `hs` also uses it for the up-front existence check. Set it to run `hs` against a non-default install, e.g. `HS_HEADSCALE_BIN=/usr/local/bin/headscale ./hs ls` |
| `HS_DEFAULT_USER` | *unset* | Fallback for `hs key new` when `-u` is omitted. With neither set, `hs` uses the only user when headscale has exactly one and otherwise fails with `a user is required: hs key new -u <name>` |
| `HS_SKIP_ROOT_CHECK` | `0` | Set to `1` to let `install.sh` / `uninstall.sh` skip the write-access check, e.g. when installing into a directory that a container wrote. Any other value leaves the check in place. `test/smoke.sh` sets it for itself; normal use should never need it |

## FAQ

### How is this different from a headscale web UI?

`headscale-ui` and `headplane` are web front ends for headscale: TLS, an auth
layer, a session, and a UI that tracks headscale's API. `hs` is the other side of
that trade-off: one bash script on the server, usually run as root over SSH, with
the same name-based commands and no credentials of its own. A web UI serves
several operators; `hs` covers the single operator working in a terminal.

### Why not just use the headscale CLI directly?

Every node command in the native CLI takes `--identifier <id>`: the ID has to be
copied from one command into the next, and one wrong ID acts on the wrong node.
`hs` resolves names itself, so `hs expire phone` is the whole command, and the
output is a table rather than a JSON dump to read by eye.

### What happens if a name matches more than one node?

Nothing is changed. The candidates are listed with their IDs and you are asked
to use one:

```
$ hs show lap
hs: ambiguous node name: lap matches several (1:laptop, 3:laptop2), use the ID instead
```

A query matches an exact `given_name`, then an exact `hostname`, then a unique
prefix — a name that merely *contains* the query never matches.

### Can I use it from a script or cron?

Yes for reads and for `--force` writes. Destructive commands (`hs rm`,
`hs user rm`) refuse to run when stdin is not a terminal, so a pipeline or a
cron job cannot delete a node by accident; pass `--force` when that is exactly
what you mean: `--force` is forwarded to headscale as well, where it is a root
flag that skips the CLI's own confirmation. A `no` at the prompt cancels the
remaining targets too: `hs rm a b` asks about each node in turn and stops at the
first refusal, printing `cancelled` and exiting 0. Read commands are safe to
pipe — `hs`'s own errors exit 1 and the columns carry no trailing whitespace.

### Does it work on IPv4-only or IPv6-only hosts?

Yes. `hs` is a local wrapper: it execs the `headscale` binary on the same machine
(which reaches the server over its local socket or the configured address) and
never opens a socket, listens on a port, or resolves a hostname itself. A host
with only IPv4, only IPv6 or both therefore behaves identically. The test suite
checks this when the tools are installed: one `hs ls` runs under `strace
-e trace=%network` and fails if an `AF_INET` socket shows up, and another runs
inside `bwrap --unshare-net` with the network namespace unshared.

Address families in the data are equally irrelevant: a node that registered with
only an IPv4 address, only an IPv6 address, or both is listed with exactly what
headscale assigned (`ADDRESS` shows `-` before addresses are assigned), and
`hs route add`/`hs route rm` treat IPv6 CIDRs like `fd00::/64` the same way as
IPv4 ones. The only requirement stays the same: the local `headscale` CLI must
work on that host.

### Does it work with headscale versions other than v0.29?

Only v0.29 is verified. The script parses headscale's `--output json` by field
name (`given_name`, `approved_routes`, `ip_addresses`, ...), so a release that
renames or reshapes those fields breaks it — re-check the JSON before bumping a
major version (see [Implementation notes](#implementation-notes)). CI runs the
integration test against two pinned `v0.29` images (the first and the latest
patch) and will gain a row when the next minor is released; there is no test
against a newer minor yet, so treat any other version as unverified.

### Where does it store state?

Nowhere. Every command shells out to `headscale` and the output is printed;
there is no cache, database or config file to back up or clean. The only
side effect is whatever headscale itself writes.

## Tests

[`test/smoke.sh`](test/smoke.sh) uses a fake `headscale`
([`test/fakebin/`](test/fakebin/)) plus fixed JSON fixtures
([`test/fixtures/`](test/fixtures/)) to check argument construction and parsing.
It does not need a real headscale and does not touch anything:

```sh
./test/smoke.sh     # prints "N passed, 0 failed" and exits non-zero on a failure
```

`./test/docs-paths.sh` checks that every repository path the README and DOCS.md
mention really exists (a path that was promised but never written is a test
failure, not a broken link someone notices later).

The install/uninstall cases write into a temporary directory and need
`HS_SKIP_ROOT_CHECK=1`, which the test sets for itself; you should never need
that variable in normal use. The IPv4/IPv6 cases also use `strace` and `bwrap`
when they are installed, and skip those two checks when they are not (`bwrap`
must also be able to unshare the network namespace).

The fake `headscale` appends every invocation's arguments to `$HS_LOG` and reads
its JSON from `$FIXTURES`, so the suite can assert on the exact argv `hs` builds
and on how it renders a given response; `test/smoke.sh` points both at its own
temporary directory.

[`test/integration.sh`](test/integration.sh) is the other half: it starts a real
headscale in Docker, registers a real node with a Tailscale client in userspace
mode, and runs `hs ls`, `hs show`, `hs route`, `hs key ls`, `hs user ls`,
`hs version` and the `--json`/`--dry-run` forms against it. Nothing is installed
on the host and no host port is used — `hs` reaches the server through a
`docker exec` wrapper, the client joins the same Docker network — and the test
is read-only apart from the writes the client needs to register:

```sh
./test/integration.sh                  # needs docker and jq
```

CI runs it against two pinned headscale images, `v0.29.0` and the latest
`v0.29.x` (`HS_IT_IMAGE` overrides the image, `HS_IT_KEEP=1` leaves the
containers and the work directory behind for debugging). A new headscale minor
gets a matrix row when it is released; until then `v0.29` is the only tested
server version.

## Mapping to the native CLI

| hs | headscale |
| --- | --- |
| `hs ls` | `headscale nodes list -o json` + jq |
| `hs rm laptop --force` | `headscale nodes delete -i <id> --force` |
| `hs rename phone pixel` | `headscale nodes rename -i <id> pixel` |
| `hs tag phone tag:x` | `headscale nodes tag -i <id> -t tag:x` |
| `hs expire phone` | `headscale nodes expire -i <id>` |
| `hs expire phone --at T` | `headscale nodes expire -i <id> -e T` |
| `hs expire phone --disable` | `headscale nodes expire -i <id> --disable` |
| `hs route add gw 10.0.0.0/8` | read `approved_routes`, then `nodes approve-routes -i <id> -r <merged>` |
| `hs route rm gw` | `nodes approve-routes -i <id> -r ""` |
| `hs key new -u alice -e 24h -r` | `preauthkeys create -u <user id> -e 24h --reusable` |
| `hs key new -u alice -t tag:vpn` | `preauthkeys create -u <user id> -e 1h --tags tag:vpn` |
| `hs key rm 3` | `preauthkeys delete -i 3` |
| `hs key expire 3` | `preauthkeys expire -i 3` |
| `hs user new carol` | `users create carol` |
| `hs user rm bob --force` | `users destroy --name bob --force` |
| `hs user rm 2 --force` | `users destroy --identifier 2 --force` |

## Implementation notes

- Parsing assumptions: in v0.29, `--output json` serialises the response structs
  with `encoding/json` without renaming, so keys are **snake_case**
  (`given_name`, `approved_routes`, `ip_addresses`, ...), `id` is a number rather
  than a string, and timestamps look like `{"seconds":...,"nanos":...}`. Re-check
  these when bumping headscale by a major version.
- Timestamps are always shown in **UTC** (jq's `todate`).
- `hs route add` sends the full merged list because headscale's
  `approve-routes` is a replace operation (`SetApprovedRoutes`).
- `hs` never opens a socket or resolves a name: it only execs `$HS_HEADSCALE_BIN`
  (the local `headscale` CLI), which is what makes IPv4-only and IPv6-only hosts
  equivalent to dual-stack ones. `IP` addresses and CIDRs are opaque strings
  passed through from headscale, not parsed or family-checked locally.
- Destructive commands refuse to run in a non-interactive shell (pipe, cron)
  unless `--force` is given.
- Reads and writes both go through the same `headscale` binary; `hs` keeps no
  state of its own. A command that needs the node list runs `nodes list -o json`
  once and keeps the JSON in a shell variable for the rest of that invocation.
- Dependencies are checked up front (`jq`, then `headscale`), so a missing
  binary is one line on stderr and exit 1 instead of a half-finished command.
  `hs help` runs before that check and works without either.

