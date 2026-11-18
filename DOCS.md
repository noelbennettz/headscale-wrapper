# hs — reference

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
- **Preauthkeys in one line**: `hs key new` prints the key and nothing else, so
  `KEY=$(hs key new -u alice -e 24h)` is the whole enrolment step
- **Errors keep headscale's reason**: the `rpc error: ... desc = ` noise is
  dropped, so `hs ls rm` says `user not found` and not just `failed`
- **Safe by default**: `hs rm` and `hs user rm` ask first and refuse to run in a
  non-interactive shell (pipe, cron) unless `--force` is given
- **Stable output for pipelines**: columns aligned by `column` when it exists
  and by an internal `awk` fallback when it does not; trailing whitespace is
  stripped, timestamps are UTC, empty values are `-`
- **IPv4, IPv6 and single-stack hosts**: node addresses are printed exactly as
  headscale reports them — IPv4-only, IPv6-only or both, `-` when none are
  assigned — and subnet routes accept `fd00::/64` as readily as `10.0.0.0/8`;
  `hs` opens no socket and resolves no name of its own, so it runs unchanged on
  IPv4-only, IPv6-only and dual-stack machines
- **No state of its own**: reads and writes both go through the same `headscale`
  binary; two runtime environment variables, no daemon and no config file

## Install, update, uninstall

`column` from util-linux is optional (there is an `awk` fallback). `jq` is a
hard requirement: without it `hs` prints a hint and exits instead of failing
halfway through.

```
hs: jq not found. Install it first (Debian/Ubuntu: apt-get install -y jq, RHEL family: dnf install -y jq)
```

Install as root:

```sh
./install.sh                 # copies to /usr/local/bin/hs (default)
./install.sh /usr/bin/hs     # or pick another path
```

You can also run it straight from the checkout, without installing:

```sh
HS_HEADSCALE_BIN=/usr/local/bin/headscale ./hs ls
```

The installer warns when `jq` or `headscale` is missing, but does not fail on
it. To update, pull and install again — `install.sh` overwrites the script in
place, so there is no state to migrate and nothing else on the machine changes:

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

It refuses to touch a file that does not look like `hs` (use `--force` to
override), and only deletes the script itself: headscale, jq and anything you
exported yourself (`HS_DEFAULT_USER` etc.) are untouched. Running it twice is
fine — the second run reports nothing to do — and it warns when another `hs`
earlier in `PATH` would still shadow the removed one.

Tested on Debian/Ubuntu with bash 5.x against headscale v0.29; nothing in the
script is Linux-specific beyond the usual coreutils.

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
`--ephemeral` and `--tag`. The node, key, route and user groups accept the
usual verb aliases (`rm`/`del`/`delete`, `ls`/`list`, `expire`/`revoke`, ...).
`hs help` runs before the dependency check and works without `jq` or
`headscale`.

### `hs node <verb>` — headscale-style spelling

Node commands also accept the two-word form you may be used to from the native
CLI: `hs node ls`, `hs node show`, `hs node rm`, `hs node rename`, `hs node
tag`, `hs node expire`, `hs node route` are exactly `hs ls`, `hs show`,
`hs rm`, ... An unknown verb is an error rather than a user filter:

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

`hs` forwards these values to headscale instead of re-implementing them, so the
formats and limits below are exactly what headscale v0.29 accepts. Anything else
comes back from the server as `parsing expiry time: ...` or
`parsing duration: ...`.

### Expiry timestamps — `hs expire --at`

`--at` is a **point in time in RFC3339 form**: full date, time and a timezone
(`Z` or `±hh:mm`). It is not a duration and not a Unix timestamp. `hs` checks
that shape before calling headscale, so typos fail fast with an `hs:` hint
instead of a server-side parse error.

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

Times are printed back in **UTC**, so a `+08:00` expiry comes back shifted.

Note the letter clash: `-e` means *timestamp* in `hs expire` but *duration* in
`hs key new`. Same letter, different grammar:

```sh
hs expire phone --at 2026-02-01T00:00:00Z   # a point in time
hs key new -u alice -e 24h                 # 24 hours from now
```

### Preauthkey lifetime — `hs key new -e`

`-e` is a **duration counted from now**, parsed by headscale with Prometheus'
duration parser. Rules:

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
`hs show`, `hs rename`, `hs tag` and `hs expire` take an ID *or* a name;
`hs user rm` treats an all-digit argument as an ID and everything else as a
name.

## Tags

Tags come from headscale's ACL vocabulary and are validated server-side: each
one must start with `tag:` (so `tag:mobile`, not `mobile`), must be lowercase
and must not contain spaces. `hs tag <node> <tag...>` replaces the whole list,
so a node ends up with exactly the tags you name.

A node cannot be left with zero tags in v0.29 — headscale rejects an empty tag
list — so `hs tag <node>` with no tags fails immediately instead of sending a
request that cannot succeed:

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
```

(The rows above come from `test/fixtures`, i.e. synthetic data.)

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or the user cancelled a confirmation prompt |
| 1 | Anything else: missing jq/headscale, unknown node, ambiguous name, headscale itself failing, refusal in a non-interactive shell |

## Environment variables

The first two are read at runtime by `hs` itself; the third only affects the installer.

| Variable | Default | Description |
|---|---|---|
| `HS_HEADSCALE_BIN` | `headscale` | Path to the headscale binary to call. Set it to run `hs` against a non-default install, e.g. `HS_HEADSCALE_BIN=/usr/local/bin/headscale ./hs ls` |
| `HS_DEFAULT_USER` | *unset* | Used when `-u` is omitted and only one user exists; set it to pin a user for `hs key new` |
| `HS_SKIP_ROOT_CHECK` | `0` | Set to `1` to let `install.sh` / `uninstall.sh` run without root. `test/smoke.sh` sets it for itself; normal use should never need it |

## FAQ

### How is this different from a headscale web UI?

`headscale-ui` and `headplane` are web front ends for headscale: TLS, an auth
layer, a session, and a UI that has to keep up with headscale's API. `hs` is
the other side of that trade-off: a single bash script on the server, run as
root over SSH, with the same name-based commands and no credentials of its own.
If you want a panel for other people, use a web UI; if you are the only
operator and you live in a terminal, this is shorter.

### Why not just use the headscale CLI directly?

Because every node command wants `--identifier <id>` — copy the ID from one
command into the next, and one wrong ID acts on the wrong node. `hs` resolves
names itself, so `hs expire phone` is the whole command, and the output is a
table rather than a JSON dump you have to read by eye.

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
what you mean. Read commands are safe to pipe — the exit code is 1 on any
failure and the columns have no trailing whitespace.

### Does it work on IPv4-only or IPv6-only hosts?

Yes. `hs` is a local wrapper: it execs the `headscale` binary on the same machine
(which talks to the server over its local socket) and never opens a socket,
listens on a port, or resolves a hostname itself. A host with only IPv4, only
IPv6 or both therefore behaves identically — the test suite checks this by
running the read commands with the network namespace unshared and by asserting
that no `AF_INET`/`AF_INET6` socket is ever created.

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
major version (see [Implementation notes](#implementation-notes)).

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
./test/smoke.sh     # 107 passed, 0 failed
```

The install/uninstall cases write into a temporary directory and need
`HS_SKIP_ROOT_CHECK=1`, which the test sets for itself; you should never need
that variable in normal use. The IPv4/IPv6 cases also use `strace` and `bwrap`
when they are installed, and skip those two checks when they are not.

## Mapping to the native CLI

| hs | headscale |
| --- | --- |
| `hs ls` | `headscale nodes list -o json` + jq |
| `hs rm laptop --force` | `headscale nodes delete -i <id> --force` |
| `hs tag phone tag:x` | `headscale nodes tag -i <id> -t tag:x` |
| `hs expire phone` | `headscale nodes expire -i <id>` |
| `hs expire phone --at T` | `headscale nodes expire -i <id> -e T` |
| `hs expire phone --disable` | `headscale nodes expire -i <id> --disable` |
| `hs route add gw 10.0.0.0/8` | read `approved_routes`, then `nodes approve-routes -i <id> -r <merged>` |
| `hs route rm gw` | `nodes approve-routes -i <id> -r ""` |
| `hs key new -u alice -e 24h -r` | `preauthkeys create -u <user id> -e 24h --reusable` |
| `hs key rm 3` | `preauthkeys delete -i 3` |
| `hs user rm bob --force` | `users destroy --name bob --force` |

## Implementation notes

- Parsing assumptions: in v0.29, `--output json` is `encoding/json` marshalling
  the protobuf structs directly, so keys are **snake_case** (`given_name`,
  `approved_routes`, `ip_addresses`, ...), `id` is a number rather than a
  string, and timestamps look like `{"seconds":...,"nanos":...}`. Re-check these
  when bumping headscale by a major version.
- Timestamps are always shown in **UTC** (jq's `todate`).
- `hs route add` sends the full merged list because headscale's
  `approve-routes` is a replace operation.
- `hs` never opens a socket or resolves a name: it only execs `$HS_HEADSCALE_BIN`
  (the local `headscale` CLI), which is what makes IPv4-only and IPv6-only hosts
  equivalent to dual-stack ones. `IP` addresses and CIDRs are opaque strings
  passed through from headscale, not parsed or family-checked locally.
- Destructive commands refuse to run in a non-interactive shell (pipe, cron)
  unless `--force` is given.
- Reads and writes both go through the same `headscale` binary; `hs` keeps no
  state of its own.
- Dependencies are checked up front (`jq`, then `headscale`), so a missing
  binary is one line on stderr and exit 1 instead of a half-finished command.
  `hs help` runs before that check and works without either.

