# Host dependency review, 2026-11-05

New packages are `uidmap` and `libsubid5`, both Ubuntu resolute
`1:4.17.4-2ubuntu3` amd64. Docker rootless extras and the Python standard library
are already installed. The installer downloads no scripts or packages. Existing
pinned GitHub Actions and the pinned runner base image are unchanged.

## Known vulnerabilities

**Finding: CVE-2024-56433, low (CVSS 3.6), remains open.** Ubuntu and Debian both
track the potential collision of default subordinate IDs with network account
IDs. There is no upstream fix recorded in those trackers. Installation requires
explicit acceptance of this finding. It has not been installed as part of this
review.

The inspected host uses `files systemd` for account lookup, has no NFS mounts,
and currently reserves only `fg:100000:65536`. The installer/controller reject
network account providers, NFS, subordinate ranges overlapping existing accounts,
and ranges overlapping another user. These checks reduce this specific risk;
they do not constitute an upstream fix or a general container-security guarantee.

Sources: [Ubuntu CVE](https://ubuntu.com/security/CVE-2024-56433),
[Debian CVE](https://security-tracker.debian.org/tracker/CVE-2024-56433),
[Debian shadow tracker](https://security-tracker.debian.org/tracker/source-package/shadow),
[upstream advisories](https://github.com/shadow-maint/shadow/security/advisories).
Other historical shadow reports cover utilities outside these two packages or
versions fixed before this release; this is not a vulnerability scan of the
entire existing host or of UCSL's separately locked dependencies.

## Publisher, integrity and install behavior

`apt-get -s install uidmap=1:4.17.4-2ubuntu3` proposes exactly these two new
packages, with no upgrades/removals. Artifacts downloaded for read-only inspection
match the SHA-256 values in the host's Ubuntu APT metadata:

| Package | SHA-256 |
| --- | --- |
| uidmap | `b4942df2976de17739887a170d51060c30ae5433fd7123b444c9ec5cef9490ff` |
| libsubid5 | `d05f5f5bda0288dffa12f01f1edbc934c477e915f6cb6d85ee5f995c75947993` |

The Ubuntu changelog identifies the February 2026 release as a no-change rebuild;
the publisher remains Ubuntu Developers. Upstream 4.17.4 has a verified signed
tag. Package control archives contain no maintainer install scripts; libsubid5
has only the normal `ldconfig` trigger. `newuidmap` and `newgidmap` deliberately
carry setuid-root permissions to establish authorized subordinate mappings.
Installation must use normal authenticated APT, without `--allow-unauthenticated`.

Sources: host APT metadata and inspected `.deb` control/data archives;
[Ubuntu package archive](https://security.ubuntu.com/ubuntu/pool/main/s/shadow/);
[upstream release](https://github.com/shadow-maint/shadow/releases/tag/4.17.4).

## Leaks and prompt injection

The two package inventories, control files, documentation and upstream
`newuidmap.c`, `newgidmap.c` and `libsubid/api.c` were inspected. No credential
payloads, telemetry or outgoing download hooks were found in that scope. The
helpers read local account/mapping information and write kernel namespace maps;
ordinary diagnostics include IDs. No claim is made to a full binary audit.

All shipped text, including decompressed documentation, was checked for invisible
direction/control characters and instruction-override phrases; no hits. Neither
package contains agent configuration, skills, hooks or MCP configuration. No
package binary or maintainer script was executed during inspection.

Sources: exact package payloads and the corresponding upstream
[UID helper](https://github.com/shadow-maint/shadow/blob/4.17.4/src/newuidmap.c),
[GID helper](https://github.com/shadow-maint/shadow/blob/4.17.4/src/newgidmap.c),
[library API](https://github.com/shadow-maint/shadow/blob/4.17.4/libsubid/api.c).

## Package rollback

After stopping the rootless user manager, `sudo apt-get remove uidmap libsubid5`
removes only these newly introduced packages. Review APT's proposed transaction;
do not use autoremove. Account, swap and systemd rollback are documented in
[README.md](README.md#rollback), with backups taken before host preparation.
