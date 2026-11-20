# hs — a name-based command line wrapper for the headscale CLI

> Applies to `v1.1.0` and the headscale v0.29 CLI. Documentation for an older
> release lives in the `README.md` and `DOCS.md` of that release's tag on
> GitHub; this tree only documents the current one.

[![Release](https://img.shields.io/badge/release-1.1.0-blue?logo=github)](https://github.com/noelbennettz/headscale-wrapper/releases)
[![headscale](https://img.shields.io/badge/headscale-v0.29-blue)](https://github.com/juanfont/headscale)
[![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?logo=gnubash&logoColor=white)](hs)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

`hs` is a bash script plus `jq` that calls the local `headscale` binary and
turns its `--identifier <id>` workflow into commands you can type: `hs show
laptop`, `hs expire phone`, `hs route add gw 10.0.0.0/8`. It parses the
`--output json` of headscale and prints aligned, stable tables that are safe to
pipe. Verified against headscale v0.29; other versions are untested because the
parsing depends on field names. It has no daemon, no config file and no web UI,
and keeps no state of its own — every command is one `headscale` call. Licence:
MIT.

## Requirements

Root (or write access to the install path), `jq`, the `headscale` binary on the
same server, and bash 5.x. `column` from util-linux is optional.

## Install

```sh
./install.sh                 # as root; copies to /usr/local/bin/hs
./install.sh /usr/bin/hs     # or pick another path
./uninstall.sh               # removes the script, nothing else
```

Updating is the same command: `git pull && ./install.sh` overwrites the script
in place, and there is no state to migrate.

## Usage

Start by listing what headscale knows about:

```console
$ hs ls
ID  NAME     USER   ADDRESS                       ONLINE   LAST SEEN             EXPIRY                TAGS
1   laptop   alice  100.64.0.1,fd7a:115c:a1e0::1  online   2026-01-01T00:00:00Z  2027-01-15T08:00:00Z  -
2   phone    alice  100.64.0.2                    offline  2025-12-31T16:53:20Z  -                     tag:mobile
```

`hs show laptop` prints one node in full, `hs expire phone --disable` or
`hs expire phone --at 2026-02-01T00:00:00Z` changes its expiry, and
`hs route add laptop 192.168.1.0/24` approves a subnet route. `hs key new -u
alice -e 24h` prints a preauthkey and nothing else, and `hs user ls`,
`hs user new <name>`, `hs user rm <name>` manage users. Destructive commands ask
first and refuse in a non-interactive shell unless `--force` is given. Add
`--json` to a read command (`hs ls --json`, `hs show laptop --json`, `hs route
--json`, `hs key ls`, `hs user ls`, `hs version`) to get headscale's JSON
instead of the table, and `--dry-run` to a write command to print the
`headscale` call it would make (`hs rm phone --dry-run`).

## Documentation

| Document | Contents |
| --- | --- |
| [DOCS.md](DOCS.md) | Full command reference, sample output, exit codes, environment variables, FAQ, mapping to the native CLI, implementation notes |
| [test/smoke.sh](test/smoke.sh) | Smoke test suite: a fake `headscale` and fixed fixtures, no real server needed |
| [test/integration.sh](test/integration.sh) | Integration test: real headscale v0.29 in Docker plus a real node, `ls`/`show`/`route`/`--json`/`--dry-run` |
| [.github/workflows/](.github/workflows/) | CI: `bash -n`, pinned `shellcheck` and `actionlint`, smoke tests, documentation path check |

## Licence

MIT — see [LICENSE](LICENSE). Keep the copyright notice and the permission text
with your copy. The runtime dependencies are not bundled and keep their own
licences: `headscale` is BSD-3-Clause and `jq` is MIT (CC-BY-3.0 for its
manual).
