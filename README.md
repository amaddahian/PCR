# pcr.sh — CockroachDB A↔B DR Playground

A cross-platform Bash helper script to spin up two local CockroachDB clusters on a single container network, seed data, start/monitor replication, perform failovers, and inspect status — all from an interactive menu.

It targets **two roles** on one bridge network `roachnet1`:

- **CA (Cluster A)** — base ports: RPC 26357, SQL 26257+, HTTP 8080+
- **CB (Cluster B)** — base ports: RPC 27357, SQL 27257+, HTTP 8090+

Containers are named `roach<N>` with volumes `roachvol<N>`. Tenants default to `va` (on CA) and `vb` (on CB).

> Tip: Run in **dry-run** mode first to see what will happen without making changes.

---

## Contents

- [Prerequisites](#prerequisites)
- [Install](#install)
- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Flags](#flags)
- [Environment variables](#environment-variables)
- [Replication & failover flows](#replication--failover-flows)
- [Status & troubleshooting](#status--troubleshooting)
- [FAQ](#faq)
- [License](#license)

---

## Prerequisites

- **Container runtime**: `podman` (preferred) or `docker`/`nerdctl` in PATH.
- **Bash 3.2+** (macOS-compatible; the script avoids `${var,,}`/`${var^^}`).
- **Python 3** (used as a portable substitute for `readlink -f` on macOS).
- **curl** (optional; used to detect a cloud VM’s public IP for DB Console URLs).
- **tput** (optional; improves color detection).
- **CockroachDB container image**: defaults to `docker.io/cockroachdb/cockroach:latest` unless overridden.

> Works on macOS and Linux. Uses portable shims for `sed -i`, `readlink -f`, `timeout`, and `base64`.

---

## Install

```bash
# Make it executable
chmod +x pcr.sh
```

> The script does nothing by default if run with no arguments. Use the `menu` command for the guided experience.

---

## Quick start

```bash
# 1) Open the interactive menu
./pcr.sh menu

# 2) From the menu:
#    1) Create CA (Cluster A)
#    2) Create CB (Cluster B)
#    3) Load initial MOVR data on CA/va
#    4) Start A → B replication
#    5) Fail over to B
#    7) Start B → A replication
#    8) Fail back to A
#    11) Check replication health
```

Or try a quick connectivity smoke test without the full menu:

```bash
./pcr.sh smoke-default
# Runs SELECT 1 on CA(default) and CB(default); exits 0 on success.
```

---

## Command reference

You can run these from the **menu** or automate them by calling functions within the script. From the CLI, the two entrypoints are:

- `menu` — launches the interactive TUI.
- `smoke-default` — runs `SELECT 1` on CA and CB using the `default` tenant.

### Menu options (0–16)

0. **Cleanup** — delete CA or CB (containers & volumes) or **both**. ⚠️ destructive.
1. **Create CA-va** — create Cluster A (choose node count & image version).
2. **Create CB-vb** — create Cluster B.
3. **Load va-1** — seed CA/`va` (creates `va_db` and runs MOVR for ~10s).
4. **A → B Start Replication** — create `vb` from replication of `va` (CB side).
5. **A → B Failover** — complete replication and start service for `vb` on CB.
6. **Load vb** — run MOVR for ~10s on CB/`vb`.
7. **B → A Start Replication** — stop `va` service, start replication of `vb` into CA.
8. **B → A Failover** — complete replication and start service for `va` on CA.
9. **Load va-2** — run another 10s of MOVR load on CA/`va`.
10. **A → B Restart Replication** — stop service and re-start replication A→B.
11. **Check replication health** — shows VC replication status plus `movr.users` counts on the appropriate tenants.
12. **Check row counts** — watches `movr.users` on CA vs CB default tenants until they match (or you quit).
13. **Run All** — full end-to-end DR flow (cleanup → create A/B → loads → A→B failover → load → B→A failover → load → health checks → A→B restart).
14. **Run ad‑hoc SQL** — interactive, lets you choose side, tenant, user, node, and SQL to run via embedded `cockroach` CLI.
15. **DB Console** — prints and tries to open CA/CB DB Console URLs, preferring first running node per side.
16. **Settings** — tweak polling limits/intervals, default image repo/version, runtime, colors, and debug.

---

## Flags

```text
-n, --dry-run                 Print commands without executing
-r, --runtime RUNTIME         Container runtime (podman|docker|nerdctl|custom)
    --max-iters N             Poll iterations for replication checks (default: MAX_ITERS)
    --interval-sec S          Poll interval seconds (default: POLL_INTERVAL)
    --ready-max-iters N       Iterations for 'ready' wait (default: READY_MAX_ITERS)
    --ready-interval-sec S    Interval for 'ready' wait (default: READY_POLL_INTERVAL)
    --init-max-iters N        Cluster init retries (default: INIT_MAX_ITERS)
    --init-interval-sec S     Interval during cluster init (default: INIT_INTERVAL)
-h, --help                    Show usage
```

> Pass flags **before** the `menu`/`smoke-default` command, e.g. `./pcr.sh -n --runtime docker menu`.

---

## Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `IMAGE_REPO` | CockroachDB image repo | `docker.io/cockroachdb/cockroach` |
| `CRDB_VERSION` | Default image tag (e.g., `24.1.17`) | `latest` |
| `RUNTIME_OVERRIDE` | Force runtime (`podman`, `docker`, etc.) | auto-detect |
| `DRY_RUN` | 1 to print instead of executing | `0` |
| `DEBUG` | Verbose debug logs | `0` |
| `MAX_ITERS` / `POLL_INTERVAL` | A→B/B→A replication polling | `60` / `5` |
| `READY_MAX_ITERS` / `READY_POLL_INTERVAL` | Failover “ready” polling | `30` / `10` |
| `INIT_MAX_ITERS` / `INIT_INTERVAL` | Cluster init retries/interval | `60` / `2` |
| `C44_STATE_FILE` | State file for saved flags | `~/.c44_state` |
| `C44_COLOR` | `auto` \| `1` \| `0` (color on/off/auto) | `auto` |
| `C44_HEADING_STYLE` | `box` \| `thick` \| `ascii` \| `rule` | `thick` |
| `C44_HEADING_WIDTH` | Width for headings (0 = auto) | `0` |
| `C44_URL_STYLE` | `auto` \| `osc8` \| `plain` \| `both` | `auto` |
| `C44_CONSOLE_IP` | Override host used in DB Console URLs | auto-detect via cloud metadata or `localhost` |

**Tenants & aliases**

- Primary tenant aliases: `va` (aka `crla`), `vb` (aka `crlb`)
- Read-only aliases: `va-readonly` (aka `crla-readonly`), `vb-readonly` (aka `crlb-readonly`)

---

## Replication & failover flows

### A → B

1. **Create clusters** (menu 1 & 2).
2. **Load CA/va** (menu 3).
3. **Start replication** A→B (menu 4) — creates `vb` from replication of `va` on CB and a `vb-readonly` shadow.
4. **Failover** (menu 5) — completes replication to latest, waits for `ready`, then starts service for `vb` and updates default target cluster.

### B → A

1. **Start replication** B→A (menu 7) — stops `va` service, starts replication of `vb` into CA, and flips default target clusters.
2. **Fail back** (menu 8) — completes replication to latest, starts `va` service (shared), and restores defaults.

> Use **menu 11** (“Check replication health”) to see `SHOW VIRTUAL CLUSTER … WITH REPLICATION STATUS` plus `SELECT count(*) FROM movr.users` on the correct tenants per direction.

---

## Status & troubleshooting

- **Status (menu 11)** prints containers, mapped SQL/HTTP ports, virtual clusters, replication status, default target clusters, and MOVR counts.
- **DB Console (menu 15)** prints/open URLs (`http://<host>:808x` for CA, `http://<host>:809x` for CB). Host is auto-detected on cloud VMs or `localhost` on desktops.
- **Row count watcher (menu 12)** keeps checking `movr.users` on CA vs CB default tenants and reports when they match.

**Common tips**

- **Dry run first**: `./pcr.sh -n menu`
- **Force runtime**: `./pcr.sh -r docker menu`
- **Pin CRDB version**: set `CRDB_VERSION=24.1.17` before creating clusters.
- **Stuck on init?** Increase `INIT_MAX_ITERS` / `INIT_INTERVAL` in **Settings** (menu 16).
- **Color issues in logs?** Toggle **Color output** in **Settings** (menu 16) or set `C44_COLOR=0`.

**Cleanup is destructive**

- **Menu 0 → 3) Remove BOTH** deletes **all** `roach*` containers, **all** `roachvol*` volumes, and `roachnet1`. Back up anything important first.

---

## FAQ

**Q: Which ports are used?**  
- CA: SQL from `26257` upward; HTTP from `8080` upward  
- CB: SQL from `27257` upward; HTTP from `8090` upward

**Q: Where do the tenants come from?**  
- Script creates/uses `va` on CA and `vb` on CB. It also uses read-only tenants (e.g., `vb-readonly`) while replication runs.

**Q: What does the smoke test do?**  
- `smoke-default` runs `SELECT 1` against CA/CB on the `default` tenant and exits with success/failure.

**Q: Can I run ad‑hoc SQL?**  
- Yes — **menu 14** prompts for side, tenant, user, node, and a one‑liner SQL string, then executes via the embedded `cockroach` binary inside the container.

---

## License

The script sets a workshop license for local testing and enables features required for replication demos.

---

**Source:** pcr.sh (see repository/script header for full details).
