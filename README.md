English | [日本語](README.ja.md)

# apt-sneakernet-skill

A [Claude](https://claude.com) Skill (web & mobile) that builds offline `.deb`
install bundles for air-gapped Debian/Ubuntu machines. Ask Claude, in chat, to
bundle some software for a given Ubuntu/Debian release — dependencies and
third-party APT repositories included — and it hands you back an archive you
can carry into the closed network on a USB drive. No CI or other external
infrastructure required.

Runs entirely inside Claude's own sandbox (the "Code Execution and File
Creation" environment available in web/mobile Claude) — nothing is installed
on your own machine.

## How it works

Under the hood, Claude builds an exact-match `debootstrap` chroot for the
target release and architecture, resolves dependencies (including
third-party repos such as PostgreSQL's official PGDG repo) with
`apt-get install --download-only`, and packages the result — `.deb` files +
manifest + install script — into a single archive.

## Motivation

Machines on a closed/air-gapped network usually need packages fetched ahead
of time on a separate, internet-connected machine — one that is often
running a different OS release than the target. Simply running
`apt-get install --download-only` on that staging machine can pull
dependency versions or binaries that don't actually match the target
release.

This Skill reproduces the target's exact apt environment locally via
`debootstrap` before downloading, so there's no version drift between what
gets fetched and what the target machine can actually install.

## Example

Ask Claude something like: "Bundle PostgreSQL 16 for offline install on
Ubuntu 24.04 (noble), including the official PGDG repo."

Behind the scenes, Claude runs `scripts/build-offline-bundle.sh`:

```bash
sudo bash scripts/build-offline-bundle.sh \
  --release noble \
  --extra-repo "deb https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
  --extra-repo-key https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  --package postgresql-16 --package postgresql-client-16 \
  --out ./postgresql-noble-bundle.tar.gz
```

Full option reference: `scripts/build-offline-bundle.sh --help`.

### More combinations

The same approach works for any release × third-party repository:

| Release | Software / repo | Verified |
|---|---|---|
| noble (24.04) | PostgreSQL official (PGDG) | Full download tested (worked example above) |
| resolute (26.04, latest LTS) | HashiCorp official (Terraform) | Full download tested |
| jammy (22.04) | Node.js official (NodeSource) | Repo resolution tested |
| noble (24.04) | Docker official | Repo resolution tested |
| bookworm (Debian 12) etc. | Swap `--mirror`/`--components` accordingly | Untested |

Contents of the generated `bundle.tar.gz`:

```
bundle/
├── MANIFEST.txt          # package names, versions, sha256
├── install-offline.sh    # run on the offline machine (roughly `sudo dpkg -i ./*.deb`)
└── *.deb                 # all collected packages
```

On the offline machine, just extract the archive and run `./install-offline.sh`.

## Requirements

- Claude (web or mobile) with its sandbox (the "Code Execution and File
  Creation" environment) enabled — root privileges and outbound HTTPS
  reachability to the package sources are available there by default
- `debootstrap` (installed automatically from apt if missing)

## Scope

- ✅ Debian/Ubuntu (APT), any release, any third-party APT repository
- ⚠️ Cross-architecture (`--arch arm64` etc.) should work in principle but is
  untested (requires `qemu-user-static` / `binfmt-support`)
- ❌ RPM-based distros (Fedora/RHEL/openSUSE) are not supported

## Installing the Skill

Add this repository as a Skill in Claude (`SKILL.md` at the repo root).
Once it's available in a conversation, just describe what you need bundled —
Claude takes care of the rest.

Implementation gotchas (CA certificate propagation, etc.) are documented in
[`references/implementation-notes.md`](references/implementation-notes.md).

## License

MIT — see [LICENSE](LICENSE).
