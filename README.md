# pcr_v1.sh — CockroachDB Local DR/Failover Toolkit

Spin up two **local** CockroachDB clusters (A and B) on a single container network, seed the Movr workload, set up **cross‑cluster replication**, run **failovers**, and practice **rolling upgrades** — all from one portable Bash script.

> **OS:** macOS & Linux • **Runtimes:** Podman / Docker / nerdctl (auto‑detect; default Podman) • **Shell:** Bash 3.2+

---

## Table of Contents
- [Why this exists](#why-this-exists)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [What gets created](#what-gets-created)
- [Menu overview](#menu-overview)
- [Commands & flags](#commands--flags)
- [Settings menu](#settings-menu)
- [Environment variables](#environment-variables)
- [Replication & failover flows](#replication--failover-flows)
- [Rolling upgrades & rollback](#rolling-upgrades--rollback)
- [Health checks & status](#health-checks--status)
- [DB Console shortcuts](#db-console-shortcuts)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## Why this exists
`pcr_v1.sh` is a **hands‑on sandbox** for CockroachDB disaster‑recovery patterns using **two local clusters**:

- **CA (Cluster A)** — primary; base ports **SQL 26257** / **HTTP 8080** / **inter‑node 26357**  
- **CB (Cluster B)** — standby; base ports **SQL 27257** / **HTTP 8090** / **inter‑node 27357**

It automates:
- Creating N‑node clusters for CA/CB on a shared network (`roachnet1`)
- Initializing tenants (`va`, `vb`, plus their `*-readonly` mirrors)
- Seeding the **Movr** sample workload
- Configuring and monitoring **replication** in both directions
- **Failover** and switching the `server.controller.default_target_cluster`
- **Rolling patch/major upgrades** (with finalize & rollback)
- Opening **DB Console** URLs

---

## Prerequisites
- Podman **or** Docker (or nerdctl) available on your `PATH` (auto‑detected; default is Podman).
- Ports **8080/8090/26257/27257** available on the host.
- Bash 3.2+ (macOS & Linux; BSD/GNU utility differences handled by the script).

---

## Quick start
```bash
# Make it executable
chmod +x pcr_v1.sh

# Launch the interactive menu
./pcr_v1.sh menu

# Optional: quick connectivity check to the default tenants on both sides
./pcr_v1.sh smoke-default
```

> Tip: Add `-n` or `--dry-run` to preview actions without executing.

---

## What gets created
**Network:** `roachnet1`  
**Containers:** `roach<N>` (e.g., `roach1..roach3` for CA; `roach4..roach6` for CB)  
**Volumes:** `roachvol<N>` (one per node)

| Role | Inter‑node | SQL (base) | HTTP (base) |
|---|---:|---:|---:|
| **CA** | 26357 | 26257 | 8080 |
| **CB** | 27357 | 27257 | 8090 |

**Tenants:** `va` / `vb`, plus `va-readonly` / `vb-readonly`.  
During failover the script updates `server.controller.default_target_cluster` so “default” clients land in the right place.

---

## Menu overview
Run `./pcr_v1.sh menu` for a guided flow. Main options:

```
0)  Cleanup
1)  Create CA-va
2)  Create CB-vb
3)  Load va-1
4)  A --> B Start Replication
5)  A --> B Failover
6)  Load vb
7)  B --> A Start Replication
8)  B --> A Failover
9)  Load va-2
10) A --> B  Restart Replication
11) Check replication health
12) Check row counts
13) Run All
14) Run ad-hoc SQL
15) DB Console
16) Settings
17) Rolling PATCH change (upgrade/downgrade)
18) Rolling MAJOR upgrade
19) Finalize MAJOR upgrade
20) Roll back to previous version
```

**Run All** executes a full scenario: cleanup → create A/B → Movr on A → A→B replication → failover A→B → Movr on B → B→A replication → failover B→A → more Movr on A → status → restart A→B → status.

**Ad‑hoc SQL** prompts for side (A/B), tenant, user, node ordinal, and the SQL to run; it prints the exact connection used.

---

## Commands & flags
### Commands
- `menu` — interactive UI  
- `smoke-default` — validates basic connectivity to tenant **default** on CA/CB (`SELECT 1`)

### Global flags
- `-n, --dry-run` — print commands without executing  
- `-r, --runtime <podman|docker|nerdctl|custom>` — choose container runtime  
- `--max-iters N`, `--interval-sec S` — replication polling (default `MAX_ITERS=60`, `POLL_INTERVAL=5s`)  
- `--ready-max-iters N`, `--ready-interval-sec S` — tenant‑ready polling (default `READY_MAX_ITERS=30`, `READY_POLL_INTERVAL=10s`)  
- `--init-max-iters N`, `--init-interval-sec S` — cluster init loop (default `INIT_MAX_ITERS=60`, `INIT_INTERVAL=2s`)  
- `-h, --help` — usage text

---

## Settings menu
From **16) Settings**, you can change:

1. **MAX_ITERS**  
2. **POLL_INTERVAL (sec)**  
3. **READY_MAX_ITERS**  
4. **READY_POLL_INTERVAL (sec)**  
5. **INIT_MAX_ITERS**  
6. **INIT_INTERVAL (sec)**  
7. **Toggle DRY_RUN**  
8. **Set Container Runtime** (podman/docker/custom)  
9. **Set Default Image Repo** (default `docker.io/cockroachdb/cockroach`)  
10. **Set Default Image Version** (`CRDB_VERSION`; blank → latest)  
11. **Toggle DEBUG**  
12. **Color output** (auto/on/off)

The menu also shows the active runtime and current values before changes.

---

## Environment variables
- `RUNTIME_OVERRIDE` / `DOCKER_CMD` — force a container runtime (otherwise auto‑detect; default Podman)  
- `IMAGE_REPO` (default `docker.io/cockroachdb/cockroach`)  
  `CRDB_VERSION` (e.g., `24.1.17`) — used when you leave version blank in create flows  
- `C44_COLOR=auto|1|0` — colorized output (respects `NO_COLOR`)  
- `DEBUG=1` — debug logging  
- `DRY_RUN=1` — dry‑run mode  
- `C44_STATE_FILE` (default `$HOME/.c44_state`) — small key=value state for replication/failover breadcrumbs  
- `C44_URL_STYLE=auto|osc8|plain|both` — how terminal links are printed

macOS shims for `sed -i`, `timeout` (via `gtimeout`), and `readlink -f` are built in.

---

## Replication & failover flows
**A → B (va → vb‑readonly)**  
1. On CB/system: `CREATE VIRTUAL CLUSTER vb FROM REPLICATION OF va ... WITH READ VIRTUAL CLUSTER`  
2. Poll until **status=replicating** and **vb‑readonly data_state=ready**  
3. **Failover A→B:** `ALTER VIRTUAL CLUSTER 'vb' COMPLETE REPLICATION TO LATEST` → `START SERVICE SHARED` → set default target cluster to `vb`

**B → A (vb → va‑readonly)** mirrors the above.  
You can start/stop/restart replication and trigger failovers via items **4–10**.

---

## Rolling upgrades & rollback
- **Patch change** (same MAJOR.MINOR): menu **17** performs a rolling image replace with readiness checks.  
- **Major upgrade**: menu **18** upgrades node‑by‑node; **19** finalizes (clears `cluster.preserve_downgrade_option`).  
- **Rollback**: menu **20** rolls back to a prior image (only **before** finalization across majors).

---

## Health checks & status
- **Status** shows containers, ports, VCs, replication status, default target cluster, and databases on the default tenant.  
- **Health check** compares `movr.users` counts using smart fallbacks depending on replication direction.  
- **Row counts watch** repeatedly checks both sides until counts match (or you exit).

---

## DB Console shortcuts
The script discovers the first running node in each role and opens/prints URLs:  
- CA: `http://localhost:8080`  
- CB: `http://localhost:8090`

In cloud shells, it attempts to detect the VM’s public IP for clickable links.

---

## Cleanup
- **Role‑only cleanup:** remove containers & volumes for CA **or** CB.  
- **Full cleanup:** remove **all** `roach*` containers, **all** `roachvol*` volumes, and the `roachnet1` network.

> Cleanup is irreversible for the local data stored in volumes.

---

**Makefile helper**

```makefile
run:
\t./pcr_v1.sh menu
```
