# pcr_v1.sh — CockroachDB Local DR/Failover Toolkit

Spin up two **local** CockroachDB clusters (A and B) on a single container network, seed the Movr workload, set up **cross‑cluster replication**, practice **failovers**, and try **rolling upgrades** — all from one portable Bash script.

> **OS:** macOS & Linux • **Runtimes:** Podman or Docker • **Shell:** Bash 3.2+

---

## Table of Contents
- [Why this exists](#why-this-exists)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [What gets created](#what-gets-created)
- [Interactive menu](#interactive-menu)
- [Commands & flags](#commands--flags)
- [Environment variables](#environment-variables)
- [Replication & failover](#replication--failover)
- [Rolling upgrades & rollback](#rolling-upgrades--rollback)
- [Health checks & status](#health-checks--status)
- [DB Console shortcuts](#db-console-shortcuts)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)
- [Notes](#notes)

---

## Why this exists
`pcr_v1.sh` is a **hands-on sandbox** for DR patterns using **two local clusters**:

- **CA (Cluster A)** — primary; base ports SQL **26257** / HTTP **8080**
- **CB (Cluster B)** — standby; base ports SQL **27257** / HTTP **8090**

It automates:
- Creating N‑node clusters for CA/CB on a shared network
- Initializing tenants (`va`, `vb`, plus their `*-readonly` mirrors)
- Seeding the **Movr** sample workload
- Configuring and monitoring **replication** in both directions
- **Failover** and switching the `server.controller.default_target_cluster`
- **Rolling patch/major upgrades** (with finalize & rollback)
- Opening **DB Console** URLs

---

## Prerequisites
- Podman **or** Docker available on your PATH (the script auto‑detects).
- Ports **8080/8090/26257/27257** free on the host.
- Bash 3.2+ (macOS and Linux supported; BSD/GNU differences handled).

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
**Containers:** `roach<N>` (e.g. `roach1..roach3` for CA; `roach4..roach6` for CB)  
**Volumes:** `roachvol<N>` (one per node)  

| Role | Inter-node | SQL (base) | HTTP (base) |
|---|---:|---:|---:|
| **CA** | 26357 | 26257 | 8080 |
| **CB** | 27357 | 27257 | 8090 |

**Tenants:** `va` / `vb`, plus `va-readonly` / `vb-readonly`.  
The script updates `server.controller.default_target_cluster` during failovers so “default” clients land on the right place.

---

## Interactive menu
Run `./pcr_v1.sh menu` for a guided flow. Options include:

```
0)  Cleanup                                   11) Check replication health
1)  Create CA-va                               12) Check row counts
2)  Create CB-vb                               13) Run All (end-to-end demo)
3)  Load va-1                                  14) Run ad-hoc SQL
4)  A → B Start Replication                    15) DB Console
5)  A → B Failover                             16) Settings
6)  Load vb                                    17) Rolling PATCH change
7)  B → A Start Replication                    18) Rolling MAJOR upgrade
8)  B → A Failover                             19) Finalize MAJOR upgrade
9)  Load va-2                                  20) Roll back to previous version
10) A → B Restart Replication                  q)  Quit
```

**Run All** executes a full scenario: cleanup → create A/B → Movr on A → A→B replication → failover A→B → Movr on B → B→A replication → failover B→A → more Movr on A → status → restart A→B → status.

---

## Commands & flags
### Commands
- `menu` — interactive UI
- `smoke-default` — runs `SELECT 1` against tenant **default** on CA and CB

### Global flags
- `-n, --dry-run` — print commands without executing  
- `-r, --runtime <podman|docker|nerdctl|custom>` — choose runtime  
- `--max-iters N`, `--interval-sec S` — polling for replication checks  
- `--ready-max-iters N`, `--ready-interval-sec S` — polling for tenant “ready”  
- `--init-max-iters N`, `--init-interval-sec S` — cluster init loop tuning  
- `-h, --help` — usage text

---

## Environment variables
- `RUNTIME_OVERRIDE` / `DOCKER_CMD` — force a container runtime
- `IMAGE_REPO` (default `docker.io/cockroachdb/cockroach`)  
  `CRDB_VERSION` (e.g. `24.1.17`) — used when you don’t specify a version in the menu
- `C44_COLOR=auto|1|0` — colorized output
- `DEBUG=1` — debug logging
- `DRY_RUN=1` — dry‑run mode
- `C44_STATE_FILE` (default `~/.c44_state`) — small key=value state
- `C44_URL_STYLE=auto|osc8|plain|both` — how terminal links are printed

macOS shims for `sed -i`, `timeout` (`gtimeout`), and `readlink -f` are built in.

---

## Replication & failover
**A → B (va → vb-readonly)**  
1. On CB/system: `CREATE VIRTUAL CLUSTER vb FROM REPLICATION OF va ... WITH READ VIRTUAL CLUSTER`  
2. Poll until **status=replicating** and **vb-readonly data_state=ready**  
3. **Failover A→B:** `ALTER VIRTUAL CLUSTER 'vb' COMPLETE REPLICATION TO LATEST` → `START SERVICE SHARED` → set default target to `vb`

**B → A (vb → va-readonly)** mirrors the steps above.

You can start/stop/restart replication and trigger failovers via the menu (items **4–10**).

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
Automatically discovers the first running node per role and opens/prints URLs:
- CA: `http://localhost:8080`
- CB: `http://localhost:8090`

In cloud shells, it attempts to detect the VM’s public IP for clickable links.

---

## Cleanup
- **Role-only cleanup:** remove containers & volumes for CA **or** CB.  
- **Full cleanup:** remove **all** `roach*` containers, **all** `roachvol*` volumes, and the `roachnet1` network.

> Cleanup is irreversible for the local data stored in volumes.

---

## Troubleshooting
- **Ports busy**: free `8080/8090/26257/27257`, or stop conflicting containers/processes.  
- **Runtime not found**: install Docker or Podman, or set `RUNTIME_OVERRIDE`.  
- **Init timing out**: the script retries `cockroach init`; check logs on the first node.  
- **Replication not “ready”**: ensure both sides are up and Movr was seeded on the source.  
- **macOS BSD tools**: differences are handled; no special flags needed.

---

## Notes
- Internal help may reference `c44.sh` in some messages; this README uses **pcr_v1.sh** naming. 
- Script prints OSC‑8 hyperlinks when supported; set `C44_URL_STYLE` to control behavior.

---

**Happy testing!** Add a quick Makefile target if you like:

```makefile
run:
\t./pcr_v1.sh menu
```
