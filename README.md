# pcr.sh — CockroachDB Local DR/Failover Toolkit

Spin up two CockroachDB clusters (A and B) on a single container network, seed data, start/monitor cross-cluster replication, perform failovers, and practice rolling upgrades — all from one portable Bash script.

> **Platforms:** macOS & Linux (BSD/GNU utilities handled)

---

## Table of Contents
- [Why this exists](#why-this-exists)
- [Quick start](#quick-start)
- [What gets created](#what-gets-created)
- [Common tasks (one-liners)](#common-tasks-one-liners)
- [Interactive menu](#interactive-menu)
- [Flags & environment](#flags--environment)
- [Replication & failover flows](#replication--failover-flows)
- [Rolling upgrades & rollback](#rolling-upgrades--rollback)
- [Status & health checks](#status--health-checks)
- [DB Console shortcuts](#db-console-shortcuts)
- [Troubleshooting](#troubleshooting)
- [Safety notes](#safety-notes)

---

## Why this exists
This script is a **hands-on sandbox** for CockroachDB disaster recovery patterns using **two local clusters**:

- **CA (Cluster A)** — primary; starts at ports 26257 (SQL) / 8080 (HTTP)
- **CB (Cluster B)** — standby; starts at ports 27257 (SQL) / 8090 (HTTP)

It includes helpers to:
- Bring up N-node clusters for CA/CB
- Initialize virtual clusters/tenants (`va`, `vb`, and their `*-readonly` clones)
- Seed the [Movr] sample workload
- Configure and monitor **replication** (A→B and B→A)
- Perform **failover** and switch the default target cluster
- Run **rolling patch/major upgrades** (with finalize & rollback helpers)
- Open **DB Console** URLs automatically

All of this works with **Docker or Podman** and is **Bash 3.2+ compatible** (portable across macOS/Linux; wrappers included for `sed -i`, `timeout`, `readlink -f`, and `base64`).

---

## Quick start
```bash
# 1) Make executable
chmod +x pcr.sh

# 2) Start the interactive menu (recommended)
./pcr.sh menu

# Or run the end‑to‑end demo (cleanup → create A/B → seed → replicate → fail over → replicate back → fail back → checks)
./pcr.sh; ./pcr.sh menu  # (menu shows "Run All")
```

> Tip: Everything here honors **dry‑run**. Add `-n/--dry-run` to print commands without executing.

---

## What gets created
**Network:** `roachnet1`

**Containers:** `roach<N>` (e.g., `roach1..roach3` for CA; `roach4..roach6` for CB)

**Volumes:** `roachvol<N>` (one per node)

**Ports (container → host mapped 1:1):**

| Role | Inter-node | SQL (base) | HTTP (base) |
|------|------------|------------|-------------|
| CA   | 26357      | 26257      | 8080        |
| CB   | 27357      | 27257      | 8090        |

**Tenants:**
- `va` (on CA), `vb` (on CB)
- Read-only mirrors: `va-readonly`, `vb-readonly`
- Aliases supported: `crla` → `va`, `crlb` → `vb`

**Default target cluster setting** is shifted during failovers so clients land on the right tenant.

---

## Common tasks (one-liners)
> Every command supports `-n/--dry-run`.

```bash
# Create a 3-node CA (Cluster A) on CockroachDB "latest"
./pcr.sh --runtime docker; ./pcr.sh menu  # pick option (1)
# or non-interactive helper inside menu flow
```

```bash
# Seed Movr on CA/va for ~10s, then show databases
./pcr.sh menu  # pick option (3)
```

```bash
# Start A → B replication (va → vb-readonly) and poll until ready
./pcr.sh menu  # pick option (4)
```

```bash
# Fail over A → B (make B readable/writable and default)
./pcr.sh menu  # pick option (5)
```

```bash
# Rolling patch change on CA (e.g., to 24.1.18)
./pcr.sh menu  # pick option (17)
```

```bash
# Health check: replication status + table counts
./pcr.sh menu  # pick option (11)
```

```bash
# Open DB Consoles for the first running nodes of each side
./pcr.sh menu  # pick option (15)
```

```bash
# Smoke test (quick SELECT 1) on tenant=default for both CA and CB
./pcr.sh smoke-default
```

```bash
# Cleanup EVERYTHING (containers, volumes, network)
./pcr.sh menu  # pick option (0) → (3)
```

---

## Interactive menu
Run `./pcr.sh menu` to get a guided flow. Highlights:

1. **Create CA** (N nodes; specify image version or use default)
2. **Create CB** (N nodes)
3. **Load Movr (A/va)**
4. **Start Replication A→B**
5. **Failover A→B**
6. **Load Movr (B/vb)**
7. **Start Replication B→A**
8. **Failover B→A**
9. **Load more Movr (A/va)**
10. **Restart Replication A→B**
11. **Check replication health**
12. **Check row counts** (live watch until equal)
13. **Run All** (full demo sequence)
14. **Ad‑hoc SQL runner** (choose side/tenant/user/node → execute)
15. **DB Console** (opens URLs for CA/CB)
16. **Settings** (tune polling, runtime, default repo/version, colors, debug)
17–20. **Rolling upgrades, finalize, rollback**

---

## Flags & environment
**Global flags**

- `-n, --dry-run` — print commands without executing
- `-r, --runtime <podman|docker|nerdctl|custom>` — choose runtime
- `--max-iters N`, `--interval-sec S` — polling for replication checks
- `--ready-max-iters N`, `--ready-interval-sec S` — polling for readiness
- `--init-max-iters N`, `--init-interval-sec S` — init loop tuning
- `-h, --help` — usage

**Subcommands**

- `menu` — interactive UI (default entrypoint if you pass `menu`)
- `smoke-default` — quick SELECT 1 on CA/CB (tenant `default`)

**Environment knobs**

- `RUNTIME_OVERRIDE`/`--runtime`/`DOCKER_CMD` — pick container runtime (auto‑detects Podman→Docker)
- `IMAGE_REPO` (default `docker.io/cockroachdb/cockroach`) & `CRDB_VERSION` (e.g. `24.1.17`)
- `C44_COLOR=auto|1|0` — colorized output; change in **Settings → Color output**
- `DEBUG=1` — debug logging
- `DRY_RUN=1` — dry‑run mode
- `C44_STATE_FILE` (default `~/.c44_state`) — small key=value state (replication/failover breadcrumbs)
- `C44_URL_STYLE=auto|osc8|plain|both` — terminal hyperlink printing style

> macOS compatibility helpers are built in for `sed -i`, `timeout` (via `gtimeout` if present), `readlink -f`, and base64 flags.

---

## Replication & failover flows
**A → B (va → vb-readonly)**
1. On CB/system, `CREATE VIRTUAL CLUSTER vb FROM REPLICATION OF va ... WITH READ VIRTUAL CLUSTER`.
2. Poll until **status=replicating** and **vb-readonly data_state=ready**.
3. **Failover A→B**: `ALTER VIRTUAL CLUSTER 'vb' COMPLETE REPLICATION TO LATEST`, then `START SERVICE SHARED`, and redirect default target cluster to `vb`.

**B → A (vb → va-readonly)** mirrors the above.

You can start/stop/restart replication and perform failovers via menu items (4–10). The script also updates the `server.controller.default_target_cluster` setting so clients without explicit `options=-ccluster=...` land in the right place during demos.

> **Tenants & aliases**: Use `va`, `vb`, `va-readonly`, `vb-readonly`, or aliases `crla`, `crlb`. The ad‑hoc SQL runner prompts you for side/tenant/user/node and prints the exact URL used.

---

## Rolling upgrades & rollback
**Patch change (within same major.minor)**
- Menu → (17) asks for target patch (e.g., `24.1.18`) and does a **rolling image replace** per node with readiness checks.

**Major upgrade**
- Menu → (18) asks for target (e.g., `24.2.0`). After all nodes run the new image, you can **Finalize** (19) to clear `cluster.preserve_downgrade_option`.

**Rollback**
- Menu → (20) runs a rolling replace back to the specified version. (Only possible **before** finalize across major versions.)

Under the hood the script:
- Pulls the requested image (`IMAGE_REPO:CRDB_VERSION` or `:latest`)
- Restarts each node with the exact same host/container ports & volumes
- Waits for SQL on the system tenant before continuing

---

## Status & health checks
- **Status summary** prints containers, ports, DB Consoles, versions, VCs, replication status, default target cluster, and databases for `default` tenant.
- **Health check** compares `movr.users` counts across the active and readonly tenants depending on the saved replication direction, with graceful fallbacks.
- **Row counts watch** repeatedly checks until CA/CB counts match (or you exit).

---

## DB Console shortcuts
The script discovers the **first running node** in each role and prints/open links like:
- CA: `http://localhost:8080`
- CB: `http://localhost:8090`

On cloud shells it attempts to detect the VM’s **public IP** (GCE/AWS/Azure metadata) so links open from your local browser.

---

## Troubleshooting
- **Ports already in use** — Stop any prior `roach*` containers or change your local services bound to `8080/8090/26257/27257`.
- **No permission to run Docker/Podman** — Ensure your user is in the right group or run with `sudo` (Podman usually doesn’t need it).
- **Cluster didn’t initialize** — The script retries `cockroach init`; check container logs for the first node.
- **Replication never reaches `replicating` / `ready`** — Verify both sides are up, the system tenant is reachable, and Movr is seeded on the source.
- **macOS `sed -i` differences** — Already handled by the script; no action needed.
- **Colors look odd in CI** — Set `C44_COLOR=0`.

---

## Safety notes
- **Cleanup (0 → 3)** removes *all* `roach*` containers, *all* `roachvol*` volumes, and the `roachnet1` network. This is irreversible for on-disk data.
- **Dry‑run** is your friend: add `-n` to preview actions before you run them for real.

---

**Happy testing!** If you want a Makefile target, add:
```makefile
run:
	./pcr.sh menu
```

> Script references and behavior summarized here are derived from the source `pcr.sh` itself.

