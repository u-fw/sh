# network

Shell tooling for provisioning and hardening Debian/Ubuntu VPS hosts, plus an
Xray deployment helper.

| Script | Purpose |
| --- | --- |
| `vps_init_tool.sh` | VPS bootstrap, audit and maintenance: swap/ZRAM, SSH hardening, UFW, Fail2ban, DNS, journald, sysctl tuning, Cloudflare origin allowlisting. |
| `freedom.sh` | Deploys Xray-core with VLESS + REALITY-VISION or XHTTP-TLS-VISION and prints a share link. |
| `xray-1stream-dat.sh` | Builds a `1stream.dat` geosite-style data file for Xray routing rules. |
| `verify.sh` | The verification suite. Static assertions plus behavioural tests that source both scripts and drive real functions against stubs. |
| `verify.ps1` | Windows entry point. Runs the static assertions natively, then delegates to `verify.sh` through WSL or Git Bash. |

All scripts target Debian/Ubuntu with systemd and expect to run as root.

## vps_init_tool.sh

Audit first, then apply. The read-only commands never modify the host:

```bash
bash vps_init_tool.sh --preflight     # environment sanity check
bash vps_init_tool.sh --audit         # full read-only audit
bash vps_init_tool.sh --ssh-audit     # SSH-specific audit
bash vps_init_tool.sh --ufw-audit     # firewall audit
bash vps_init_tool.sh                 # interactive menu
```

Mutating commands ask for confirmation unless `--yes` is given:

```bash
bash vps_init_tool.sh --baseline --yes                   # safe low-risk baseline
bash vps_init_tool.sh --optimize-auto --yes              # safe automatic tier
bash vps_init_tool.sh --ufw-cf-sync --ports 80,443 --yes # Cloudflare-only origin rules
```

SSH hardening, UFW initialisation, swap and DNS changes are currently reachable
only from the interactive menu.

### Safety model

Every risky change is staged to a temporary file, validated, installed
atomically, then verified — and rolled back from a backup if any step fails.
Backups live under `/root/vps-init-backups` and are pruned to the newest
`VPS_INIT_BACKUP_KEEP` (default 10) per target. `--list-backups` shows them.

SSH hardening additionally refuses to run when sshd is socket-activated (the
listening port then comes from `ssh.socket`, not `sshd_config`), rejects a
configuration whose effective port set is not exactly the requested port
(sshd *accumulates* `Port` directives rather than overriding them), opens the
new port in UFW before reloading, and confirms afterwards that something is
actually listening before reporting success.

**Keep your current SSH session open until you have verified a new login.**

## freedom.sh

```bash
bash freedom.sh                       # interactive deployment
bash freedom.sh --check               # read-only preflight, no changes
bash freedom.sh --port 443 --sni example.com --node-name my-node
```

Passing any option that carries a deployment setting (`--port`, `--sni`,
`--mode`, ...) or `--non-interactive` runs unattended with defaults for omitted
values. Plain toggles such as `--no-qr`, `--yes` or `--skip-sni-check` do not by
themselves leave interactive mode.

Configuration is generated with `jq`, validated with `xray run -test`, and
installed atomically. The previous config is backed up and restored if anything
fails. `bash freedom.sh --help` lists every flag and environment variable.

## Verification

```bash
bash verify.sh          # on Linux, WSL or Git Bash
pwsh -File verify.ps1   # on Windows; delegates to verify.sh
```

`verify.sh` runs static assertions over the script sources, behavioural tests
that source both scripts (`VPS_INIT_LIB_ONLY=1` / `FREEDOM_LIB_ONLY=1`) and
exercise real functions against stubs, and `shellcheck` at default severity with
no per-file exemptions.

Checks that cannot run in the current environment print `[SKIP]` with the
reason rather than counting as a pass — a missing `shellcheck` or `jq`, or a
filesystem that does not preserve POSIX mode bits (Git Bash on NTFS reports
every file as `644` regardless of `chmod`).

Set `VERIFY_STRICT=1` to turn every such skip into a failure. CI sets it on both
entry points, so no part of the suite can skip its way to green there. On
`verify.ps1` it additionally makes "no WSL/Git Bash to delegate to" a failure
instead of a partial pass.

### Adding checks

Prefer behavioural tests over source-text assertions. A `grep` for a source line
breaks on harmless refactors and still passes when the same logic is moved
somewhere it no longer protects anything. When a source-text assertion is the
only practical option, extract the real pattern from the script under test
rather than restating it in the test — a restated copy only tests itself.

`verify.sh` fails if any static pattern also matches unrelated text, which
catches assertions that can never fail (for example an unescaped `||`, which ERE
reads as an alternation with an empty branch).
