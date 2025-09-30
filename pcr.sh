#!/usr/bin/env bash
# --- cross-platform portability shim (macOS + Ubuntu) -------------------------
# Bash + safety
set -Eeuo pipefail

# Case helpers (Bash 3.2-safe; replaces ${var,,} / ${var^^})
type _lower >/dev/null 2>&1 || _lower() { printf '%s' "$*" | tr '[:upper:]' '[:lower:]'; }
type _upper >/dev/null 2>&1 || _upper() { printf '%s' "$*" | tr '[:lower:]' '[:upper:]'; }

# Colors (nounset-safe)
: "${C44_COLOR:=1}"; : "${NO_COLOR:=}"
if [[ -n "${NO_COLOR:-}" ]]; then C44_COLOR=0; fi
if [[ "${C44_COLOR:-1}" == "1" && -t 1 ]]; then
  RESET=$'\033[0m'; YELLOW_BOLD=$'\033[1;33m'; BLUE_BOLD=$'\033[1;94m'
  CYAN_BOLD=$'\033[1;36m'; PURPLE_BOLD=$'\033[1;35m'; RED_BOLD=$'\033[1;31m'
else
  RESET=""; YELLOW_BOLD=""; BLUE_BOLD=""; CYAN_BOLD=""; PURPLE_BOLD=""; RED_BOLD=""
fi
NC="${RESET}"
_printc() { local c="${1:-}"; shift || true; if [[ -t 1 && -n "${c:-}" ]]; then printf "%b%s%b\n" "$c" "$*" "$NC"; else printf "%s\n" "$*"; fi; }

# OS detection
_is_macos() { [[ "${OSTYPE:-}" == darwin* ]]; }
_is_linux() { [[ "${OSTYPE:-}" == linux* ]]; }

# sed -i wrapper (BSD vs GNU)
_sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@";            # GNU sed
  else sed -i '' "$@"; fi                                        # BSD sed
}

# base64 decode wrapper (GNU -d, BSD -D)
_b64d() { base64 -d 2>/dev/null || base64 -D; }
_b64e() { base64; }

# readlink -f wrapper (BSD lacks -f)
_readlink_f() {
  if readlink -f "$1" 2>/dev/null; then return 0; fi
  python3 - <<'PY' "$1"
import os, sys; print(os.path.realpath(sys.argv[1]))
PY
}

# timeout wrapper (use gtimeout on mac if available; else passthrough)
_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else shift $#; "$@"
  fi
}

# Confirmation + dry-run (nounset-safe)
_confirm() { local p="${1:-Proceed? [y/N]: }" d="${2:-N}" a=""; read -r -p "$p" a || a=""; a="${a:-$d}"; [[ "$a" =~ ^[Yy]$ ]]; }
_is_dry() { [[ "${DRY_RUN:-0}" == "1" || "${DRY:-0}" == "1" || "${NOEXEC:-0}" == "1" ]]; }
_dry_echo() { if _is_dry; then _printc "$YELLOW_BOLD" "[dry-run] $*"; else "$@"; fi; }

# Global container runtime (constant for entire run)
RUNTIME="${RUNTIME:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
_default_runtime() { printf '%s\n' "$RUNTIME"; }

# Guard common envs used under 'set -u'
: "${POLL_INTERVAL:=2}"; : "${MAX_ITERS:=90}"
: "${current_step:=}"
# -----------------------------------------------------------------------------
# c44.sh — CockroachDB cluster helpers: CA + CB (both on roachnet1) + status + destroy + SQL runner + menu + settings
# - Volumes: roachvol<N>      (e.g., roachvol1)
# - Containers: roach<N>      (e.g., roach1)
# - CA listen (internode/RPC): 26357; CA SQL base: 26257; HTTP base: 8080
# - CB listen (internode/RPC): 27357; CB SQL base: 27257; HTTP base: 8090
# DRY RUN via --dry-run / -n, runtime via --runtime / -r (default podman).
# DEBUG=1 to enable debug logs.
#
# Changes vs c43.sh:
# - Fixed _map_tenant_alias (no stray echo; preserves/normalizes known aliases).
# - Unified read-only flag to READ_VC and updated all call sites.
# - Removed stray debug echos and gated optional logs behind DEBUG.
# - Fixed workload URLs to use ?options=-ccluster=<tenant>&sslmode=disable.
# - Removed unintended unconditional SQL execution at end of file.
# - Added --help flag and usage text.
# - Minor robustness (node selection for workloads) and comments.
#
# NOTE: This script expects CockroachDB images exposing ./cockroach CLI inside containers.

set -o errexit
set -o nounset
set -o pipefail

# ===========================
# Global flags & defaults
# ===========================

# ===========================
# Color defaults (safe under set -u) + toggle
# ===========================
# Safe empty defaults to avoid 'unbound variable' with set -u
: "${RESET:=}"
: "${RED_BOLD:=}"
: "${GREEN_BOLD:=}"
: "${YELLOW_BOLD:=}"
: "${BLUE_BOLD:=}"
: "${PURPLE_BOLD:=}"
: "${CYAN_BOLD:=}"

# Toggle: C44_COLOR=0|1|auto (default: auto)
: "${C44_COLOR:=auto}"

_supports_colors() {
  # stdout is a TTY and terminal supports >=8 colors
  if [[ -t 1 ]]; then
    if command -v tput >/dev/null 2>&1; then
      local n; n="$(tput colors 2>/dev/null || echo 0)"
      [[ "${n:-0}" -ge 8 ]] && return 0
    else
      # Fallback heuristic: assume color if TTY and no tput
      return 0
    fi
  fi
  return 1
}

_enable_colors_if_requested() {
  local want="${C44_COLOR}"
  if [[ "${want}" == "1" ]] || { [[ "${want}" == "auto" ]] && _supports_colors; }; then
    RESET=$'\e[0m'
    RED_BOLD=$'\e[1;31m'
    GREEN_BOLD=$'\e[1;32m'
    YELLOW_BOLD=$'\e[1;33m'
    BLUE_BOLD=$'\e[1;34m'
    PURPLE_BOLD=$'\e[1;35m'
    CYAN_BOLD=$'\e[1;36m'
  fi
}
_enable_colors_if_requested


# ===========================
# Persistent state (key=value file)
# ===========================
C44_STATE_FILE="${C44_STATE_FILE:-$HOME/.c44_state}"

_state_get() {
  local key="$1"; [[ -f "$C44_STATE_FILE" ]] || return 1
  awk -F= -v k="$key" '$1==k { $1=""; sub(/^=/, "", $0); print; exit }' "$C44_STATE_FILE"
}

_state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$C44_STATE_FILE")" 2>/dev/null || true
  if [[ -f "$C44_STATE_FILE" ]] && grep -q "^${key}=" "$C44_STATE_FILE"; then
    if sed --version >/dev/null 2>&1; then
      sed -i "s|^${key}=.*|${key}=${val//|/\\|}|" "$C44_STATE_FILE"
    else
      sed -i '' "s|^${key}=.*|${key}=${val//|/\\|}|" "$C44_STATE_FILE"
    fi
  else
    printf "%s=%s\n" "$key" "$val" >> "$C44_STATE_FILE"
  fi
}

_state_del() {
  local key="$1"; [[ -f "$C44_STATE_FILE" ]] || return 0
  if sed --version >/dev/null 2>&1; then
    sed -i "/^${key}=/d" "$C44_STATE_FILE"
  else
    sed -i '' "/^${key}=/d" "$C44_STATE_FILE"
  fi
}

_state_true() {
  local v; v="$(_state_get "$1" 2>/dev/null || echo "")"
  case "${v,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

DRY_RUN="${DRY_RUN:-0}"
RUNTIME_OVERRIDE="${RUNTIME_OVERRIDE:-}"
DEBUG="${DEBUG:-0}"

# Poll loop controls (flags or env)
MAX_ITERS="${MAX_ITERS:-60}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
READY_MAX_ITERS="${READY_MAX_ITERS:-30}"
READY_POLL_INTERVAL="${READY_POLL_INTERVAL:-10}"
INIT_MAX_ITERS="${INIT_MAX_ITERS:-60}"
INIT_INTERVAL="${INIT_INTERVAL:-2}"

MODE=""  # optional subcommand like "menu"

# tiny logger
log() { [[ "${DEBUG}" == "1" ]] && printf "[DEBUG] %s\n" "$*" >&2 || true; }

print_usage() {
  cat <<'EOF'
Usage: c44.sh [flags] [menu]

Flags:
  -n, --dry-run                 Print commands without executing
  -r, --runtime RUNTIME         Container runtime (podman|docker|nerdctl|custom)
      --max-iters N            Poll iterations for replication checks (default: $MAX_ITERS)
      --interval-sec S         Poll interval seconds (default: $POLL_INTERVAL)
      --ready-max-iters N      Poll iterations for "ready" (default: $READY_MAX_ITERS)
      --ready-interval-sec S   Poll interval for "ready" (default: $READY_POLL_INTERVAL)
      --init-max-iters N       Iterations when running cluster init (default: $INIT_MAX_ITERS)
      --init-interval-sec S    Interval during cluster init (default: $INIT_INTERVAL)
  -h, --help                    Show this help

Commands:
  menu                         Interactive menu (default entrypoint)
EOF
  echo "  smoke-default     Run SELECT 1 via tenant=\"default\" on CA and CB"
}
# simple flag parser
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --runtime|-r) [[ $# -ge 2 ]] || { echo "Error: --runtime requires an argument"; exit 2; }
                  RUNTIME_OVERRIDE="$2"; shift 2 ;;
    --max-iters)  [[ $# -ge 2 ]] || { echo "Error: --max-iters N"; exit 2; }
                  MAX_ITERS="$2"; shift 2 ;;
    --interval-sec) [[ $# -ge 2 ]] || { echo "Error: --interval-sec S"; exit 2; }
                  POLL_INTERVAL="$2"; shift 2 ;;
    --ready-max-iters) [[ $# -ge 2 ]] || { echo "Error: --ready-max-iters N"; exit 2; }
                  READY_MAX_ITERS="$2"; shift 2 ;;
    --ready-interval-sec) [[ $# -ge 2 ]] || { echo "Error: --ready-interval-sec S"; exit 2; }
                  READY_POLL_INTERVAL="$2"; shift 2 ;;
    --init-max-iters) [[ $# -ge 2 ]] || { echo "Error: --init-max-iters N"; exit 2; }
                  INIT_MAX_ITERS="$2"; shift 2 ;;
    --init-interval-sec) [[ $# -ge 2 ]] || { echo "Error: --init-interval-sec S"; exit 2; }
                  INIT_INTERVAL="$2"; shift 2 ;;
smoke-default) MODE="smoke-default"; shift; break ;;
    menu) MODE="menu"; shift; break ;;
    --help|-h) print_usage; exit 0 ;;
    *) break ;;
  esac
done

# ===========================
# License / tenant variables
# ===========================
lic="crl-0-EJOAsccGGAIiCFdvcmtzaG9w"
VA="va"
VB="vb"
PG_SYSTEM="options=-ccluster=system"
READ_VC="WITH READ VIRTUAL CLUSTER"

# ===========================
# Colors + tiny print helper
# ===========================
YELLOW_BOLD=$'\033[1;33m'
BLUE_BOLD=$'\033[1;94m'
CYAN_BOLD=$'\033[1;36m'
PURPLE_BOLD=$'\033[1;35m'
RED_BOLD=$'\033[1;31m'
NC=$'\033[0m'
_printc() { local color="${1:-}"; shift || true
  if [[ -t 1 && -n "${color:-}" ]]; then printf "%b%s%b\n" "$color" "$*" "$NC"; else printf "%s\n" "$*"; fi; }
_is_dry() { [[ "${DRY_RUN:-0}" == "1" ]]; }

# Bold RED confirmation prompts (affects all menu confirms)
_confirm() {
  local prompt="${1:-Are you sure? [y/N]: }"
  local ans
  if [[ -t 1 ]]; then
    read -r -p "$(printf "%b%s%b" "$RED_BOLD" "$prompt" "$NC")" ans || { echo "Cancelled."; return 1; }
  else
    read -r -p "$prompt" ans || { echo "Cancelled."; return 1; }
  fi
  case "$ans" in y|Y|yes|YES) return 0 ;; *) echo "Cancelled."; return 1 ;; esac
}

_default_runtime() { echo "${RUNTIME_OVERRIDE:-${docker_command:-${DOCKER_CMD:-podman}}}"; }

_echo_cmd() { printf "[DRY-RUN] "; printf "%q " "$@"; printf "\n"; }
_exec() { if _is_dry; then _echo_cmd "$@"; else "$@"; fi; }

# ===========================
# Alias helpers (backward-compat)
# ===========================
_canon_cluster() {
  # Map many spellings → CA|CB
  case "${1,,}" in
    ca|a|1|primary|p) echo "CA" ;;
    cb|b|2|standby|s) echo "CB" ;;
    *) return 1 ;;
  esac
}

_map_tenant_alias() {
  # Normalize known aliases; preserve others
  case "${1,,}" in
    crla) echo "va" ;;
    crlb) echo "vb" ;;
    crla-readonly) echo "va-readonly" ;;
    crlb-readonly) echo "vb-readonly" ;;
    va|vb|va-readonly|vb-readonly|system) echo "${1,,}" ;;
    *) echo "$1" ;;
  esac
}

# ===========================
# Container/cluster helpers
# ===========================
_next_roach_start() {
  local runtime="${1:-$(_default_runtime)}"
  if _is_dry; then echo 1; return; fi
  local highest=0
  while IFS= read -r name; do
    if [[ "$name" =~ ^roach([0-9]+)$ ]]; then local idx="${BASH_REMATCH[1]}"; (( idx > highest )) && highest="$idx"; fi
  done < <($runtime ps -a --format '{{.Names}}' | grep -E '^roach[0-9]+$' || true)
  echo $((highest + 1))
}

_list_roach_on_roachnet1() {
  local runtime="${1:?}"
  if _is_dry; then echo ""; return; fi
  $runtime ps -a --filter "network=roachnet1" --format '{{.Names}}' \
    | grep -E '^roach[0-9]+$' \
    | sed 's/^roach//' | sort -n | sed 's/^/roach/' || true
}

_is_role_container() {
  local runtime="${1:?}" name="${2:?}" role="${3:?}" line cport
  if _is_dry; then return 1; fi
  local want_low want_high
  case "$role" in CA) want_low=26257; want_high=26999 ;; CB) want_low=27257; want_high=27999 ;; *) return 1 ;; esac
  while IFS= read -r line; do
    cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue
    if (( cport >= want_low && cport <= want_high )); then return 0; fi
  done <<< "$($runtime port "$name" 2>/dev/null || true)"
  return 1
}

_get_names_by_role() {
  local runtime="${1:?}" role_in="${2:?}"
  local role; role="$(_canon_cluster "$role_in" 2>/dev/null || echo "$role_in")"
  if _is_dry; then echo ""; return; fi
  local all; all="$(_list_roach_on_roachnet1 "$runtime")"
  local out=()
  while IFS= read -r n; do [[ -z "$n" ]] && continue; _is_role_container "$runtime" "$n" "$role" && out+=("$n"); done <<< "$all"
  (IFS=$'\n'; printf "%s\n" "${out[@]:-}") | sed 's/^roach//' | sort -n | sed 's/^/roach/'
}

_resolve_and_pull_image() {
  local runtime_arg="${1:-}" version_arg="${2:-}" color="${3:-}"
  local runtime
  if [[ -n "$runtime_arg" ]]; then runtime="$runtime_arg"
  elif [[ -n "${docker_command:-}" ]]; then runtime="${docker_command}"
  elif [[ -n "${DOCKER_CMD:-}" ]]; then runtime="${DOCKER_CMD}"
  else runtime="$(_default_runtime)"; fi

  local ver
  if [[ -n "$version_arg" ]]; then ver="$version_arg"
  elif [[ -n "${version:-}" ]]; then ver="${version}"
  elif [[ -n "${CRDB_VERSION:-}" ]]; then ver="${CRDB_VERSION}"
  else ver="latest"; fi
  [[ "$ver" =~ ^[0-9] ]] && ver="v${ver}"

  local repo="${IMAGE_REPO:-docker.io/cockroachdb/cockroach}"
  local image="${repo}:${ver}"

  if [[ -n "$color" && -t 2 ]]; then printf "%b%s%b\n" "$color" "Ensuring image available: $image" "$NC" 1>&2; else echo "Ensuring image available: $image" 1>&2; fi
  _exec "$runtime" pull "$image" 1>&2
  echo "$runtime"; echo "$image"
}

_start_roach_block() {
  local n="$1" runtime="$2" image="$3" network="$4" inter_port="$5" http_base="$6" sql_base="$7" color="$8"
  local start; start=$(_next_roach_start "$runtime")
  local -a names=() http_ports=() sql_ports=() joins=() volnames=()
  for ((i=0; i<n; i++)); do
    local node_num=$(( start + i ))
    names+=("roach${node_num}")
    volnames+=("roachvol${node_num}")
    http_ports+=($(( http_base + i )))
    sql_ports+=($(( sql_base + i )))
    joins+=("roach${node_num}:${inter_port}")
  done
  local join_csv; join_csv="$(IFS=,; echo "${joins[*]}")"

  if _is_dry; then
    _printc "$color" "(DRY-RUN) Would ensure network and volumes, then run nodes:"
    _echo_cmd "$runtime" network create -d bridge "$network"
    for vol in "${volnames[@]}"; do _echo_cmd "$runtime" volume create "$vol"; done
    for ((i=0; i<n; i++)); do
      _echo_cmd "$runtime" run -d \
        --name="${names[i]}" --hostname="${names[i]}" --net="$network" \
        -p "${sql_ports[i]}:${sql_ports[i]}" -p "${http_ports[i]}:${http_ports[i]}" \
        -v "${volnames[i]}:/cockroach/cockroach-data" \
        "$image" start \
          --advertise-addr="${names[i]}:${inter_port}" \
          --http-addr="${names[i]}:${http_ports[i]}" \
          --listen-addr="${names[i]}:${inter_port}" \
          --sql-addr="${names[i]}:${sql_ports[i]}" \
          --insecure \
          --join="$join_csv"
    done
    _printc "$color" "Inter-node: ${inter_port} | HTTP: ${http_ports[*]} | SQL: ${sql_ports[*]}"
    return
  fi

  if ! $runtime network inspect "$network" >/dev/null 2>&1; then
    _printc "$color" "$runtime network create -d bridge $network"
    _exec "$runtime" network create -d bridge "$network"
  else
    _printc "$color" "Network $network already exists."
  fi

  for vol in "${volnames[@]}"; do
    if ! $runtime volume inspect "$vol" >/dev/null 2>&1; then
      _printc "$color" "$runtime volume create $vol"
      _exec "$runtime" volume create "$vol" >/dev/null 2>&1 || true
    else
      _printc "$color" "Volume $vol already exists."
    fi
  done

  _printc "$color" ""
  _printc "$color" "Starting cluster on '$network' with nodes: ${names[*]}"
  _printc "$color" "Inter-node: ${inter_port} | HTTP: ${http_ports[*]} | SQL: ${sql_ports[*]}"
  _printc "$color" ""

  for ((i=0; i<n; i++)); do
    _printc "$color" "Launching ${names[i]} (vol=${volnames[i]}, SQL ${sql_ports[i]}, HTTP ${http_ports[i]}, inter-node ${inter_port})..."
    _exec "$runtime" run -d \
      --name="${names[i]}" --hostname="${names[i]}" --net="$network" \
      -p "${sql_ports[i]}:${sql_ports[i]}" -p "${http_ports[i]}:${http_ports[i]}" \
      -v "${volnames[i]}:/cockroach/cockroach-data" \
      "$image" start \
        --advertise-addr="${names[i]}:${inter_port}" \
        --http-addr="${names[i]}:${http_ports[i]}" \
        --listen-addr="${names[i]}:${inter_port}" \
        --sql-addr="${names[i]}:${sql_ports[i]}" \
        --insecure \
        --join="$join_csv"
  done

  _printc "$color" ""
  _printc "$color" "Cluster started:"
  for ((i=0; i<n; i++)); do
    _printc "$color" " - ${names[i]}  |  Vol: ${volnames[i]}  |  Console: http://localhost:${http_ports[i]}  |  SQL: localhost:${sql_ports[i]}"
  done
}

# ===========================
# CA / CB cluster creators
# ===========================
create_CA_cluster() {
  heading "Create Cluster A (CA)" "Default topology"

  local n="${1:?Usage: create_CA_cluster <n> [runtime] [image_version] }"
  local runtime_arg="${2:-}" version_arg="${3:-}"
  local resolved; resolved="$(_resolve_and_pull_image "$runtime_arg" "$version_arg" "$YELLOW_BOLD")"
  local runtime image; runtime="$(echo "$resolved" | sed -n '1p')"; image="$(echo "$resolved" | sed -n '2p')"

  _start_roach_block "$n" "$runtime" "$image" "roachnet1" 26357 8080 26257 "$YELLOW_BOLD"

  _printc "$YELLOW_BOLD" "Waiting for roach1 to be ready (init)..."
  if _is_dry; then
    _echo_cmd "$runtime" exec -t roach1 ./cockroach --host=roach1:26357 init --insecure
  else
    local output="" init_done=0
    for ((i=1; i<=INIT_MAX_ITERS; i++)); do
      output="$($runtime exec -t roach1 ./cockroach --host=roach1:26357 init --insecure 2>&1 || true)"
      if echo "$output" | grep -qi 'already.*initialized'; then _printc "$YELLOW_BOLD" "Cluster already initialized."; init_done=1; break; fi
      if echo "$output" | grep -qi 'initialized'; then _printc "$YELLOW_BOLD" "Cluster initialized successfully."; init_done=1; break; fi
      sleep "$INIT_INTERVAL"
    done
    (( init_done == 0 )) && { _printc "$YELLOW_BOLD" "WARNING: init did not succeed. Last output:"; _printc "$YELLOW_BOLD" "$output"; }
  fi

  _printc "$YELLOW_BOLD" "Applying system-tenant settings and creating '${VA}'..."
  set +e
  run_roach_sql CA "SET CLUSTER SETTING cluster.organization = 'Workshop';" system root 1 "$runtime" || true
  run_roach_sql CA "SET CLUSTER SETTING enterprise.license = '${lic}';" system root 1 "$runtime" || true
  run_roach_sql CA "CREATE VIRTUAL CLUSTER IF NOT EXISTS ${VA};" system root 1 "$runtime" || true
  run_roach_sql CA "ALTER VIRTUAL CLUSTER ${VA} START SERVICE SHARED;" system root 1 "$runtime" || true
  run_roach_sql CA "SET CLUSTER SETTING server.controller.default_target_cluster = '${VA}';" system root 1 "$runtime" || true
  run_roach_sql CA "SET CLUSTER SETTING kv.rangefeed.enabled = true;" system root 1 "$runtime" || true
  set -e
}

create_CB_cluster() {
    local y=""
heading "Create Cluster B (CB)" "Default topology"

  local n="${1:?Usage: create_CB_cluster <n> [runtime] [image_version] }"
  local runtime_arg="${2:-}" version_arg="${3:-}"
  local resolved; resolved="$(_resolve_and_pull_image "$runtime_arg" "$version_arg" "$BLUE_BOLD")"
  local runtime image; runtime="$(echo "$resolved" | sed -n '1p')"; image="$(echo "$resolved" | sed -n '2p')"

  local start_index; start_index=$(_next_roach_start "$runtime"); local first_node="roach${start_index}"
  local listen_port=27357
  _start_roach_block "$n" "$runtime" "$image" "roachnet1" "$listen_port" 8090 27257 "$BLUE_BOLD"

  _printc "$BLUE_BOLD" "Waiting for ${first_node} to be ready (init)..."
  if _is_dry; then
    _echo_cmd "$runtime" exec -it "${first_node}" ./cockroach --host="${first_node}:${listen_port}" init --insecure
  else
    local output="" init_done=0
    for ((i=1; i<=INIT_MAX_ITERS; i++)); do
      if ! $runtime ps -a --format '{{.Names}}' | grep -qx "${first_node}"; then sleep "$INIT_INTERVAL"; continue; fi
      local state="$($runtime inspect -f '{{.State.Status}}' "${first_node}" 2>/dev/null || echo notfound)"
      [[ "$state" != "running" ]] && { sleep "$INIT_INTERVAL"; continue; }
      output="$($runtime exec -it "${first_node}" ./cockroach --host="${first_node}:${listen_port}" init --insecure 2>&1 || true)"
      if echo "$output" | grep -qi 'already.*initialized'; then _printc "$BLUE_BOLD" "CB already initialized."; init_done=1; break; fi
      if echo "$output" | grep -qi 'initialized'; then _printc "$BLUE_BOLD" "CB initialized successfully."; init_done=1; break; fi
      sleep "$INIT_INTERVAL"
    done
    (( init_done == 0 )) && { _printc "$BLUE_BOLD" "WARNING: CB init did not succeed. Last output:"; _printc "$BLUE_BOLD" "$output"; }
  fi

  _printc "$BLUE_BOLD" "Applying system-tenant settings on CB..."
  set +e
  run_roach_sql CB "SET CLUSTER SETTING cluster.organization = 'Workshop';" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING enterprise.license = '${lic}';" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING server.controller.default_target_cluster = '${VB}-readonly';" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING kv.rangefeed.enabled = true;" system root 1 "$runtime" || true
  set -e
}

# ===========================
# SQL runner (accepts CA/CB and primary/standby)
# ===========================
run_roach_sql() {
  local cluster_arg_in="${1:?Usage: run_roach_sql <CA|CB|primary|standby|1|2> \"SQL\" [tenant] [user] [node_ordinal] [runtime] }"
  local sql="${2:?Missing SQL string}"
  local tenant_in="${3:-system}" user="${4:-root}" ordinal="${5:-1}" runtime_arg="${6:-}"
  local tenant; tenant="$(_map_tenant_alias "$tenant_in")"

  local runtime
  if [[ -n "$runtime_arg" ]]; then runtime="$runtime_arg"
  elif [[ -n "${docker_command:-}" ]]; then runtime="${docker_command}"
  elif [[ -n "${DOCKER_CMD:-}" ]]; then runtime="${DOCKER_CMD}"
  else runtime="$(_default_runtime)"; fi

  local role; role="$(_canon_cluster "$cluster_arg_in" 2>/dev/null || true)"
  local base_sql color label
  case "${role:-}" in
    CA) base_sql=26257; color="$YELLOW_BOLD"; label="CA" ;;
    CB) base_sql=27257; color="$BLUE_BOLD";   label="CB" ;;
    *) echo "Invalid cluster '${cluster_arg_in}'. Use CA|CB|primary|standby|1|2."; return 1 ;;
  esac

  if ! [[ "$ordinal" =~ ^[0-9]+$ && "$ordinal" -ge 1 ]]; then echo "node_ordinal must be a positive integer"; return 1; fi

  local node
  if _is_dry; then
    node=$([[ "$role" == "CA" ]] && echo "roach1" || echo "roach4")
  else
    local names; names="$(_get_names_by_role "$runtime" "$role")"; node="$(echo "$names" | sed -n "${ordinal}p")"
    [[ -z "${node:-}" ]] && { echo "Could not find node ordinal ${ordinal} for '${role}'."; return 1; }
  fi

  local sql_port=$(( base_sql + ordinal - 1 ))
  local url="postgresql://${user}@${node}:${sql_port}?options=-ccluster=${tenant}&sslmode=disable"
  if [[ "${tenant}" == "default" ]]; then url="postgresql://${user}@${node}:${sql_port}"; fi

  _printc "$color" "Executing on ${label} | node=${node} | tenant=${tenant} | user=${user}"
  _printc "$color" "URL: ${url}"

  if _is_dry; then _echo_cmd "$runtime" exec -it "${node}" ./cockroach sql --format=table --echo-sql --execute "${sql}" --insecure --url "${url}"; return 0; fi

  local tty_flags="-i"; [[ -t 1 ]] && tty_flags="-it"
  [[ -t 1 ]] && printf "%b" "$color"
  $runtime exec $tty_flags "${node}" ./cockroach sql --format=table --echo-sql --execute "${sql}" --insecure --url "${url}"
  local rc=$?
  [[ -t 1 ]] && printf "%b" "$NC"
  return "$rc"
}

# Interactive ad-hoc SQL
run_sql_interactive() {
  local runtime="${1:-$(_default_runtime)}"
  echo
  echo "Run ad-hoc SQL:"
  echo -n "Which side? [A=CA, B=CB] (default A): "
  read -r side; side="${side:-A}"
  local cluster default_tenant
  case "${side,,}" in
    a|ca|1|primary|p) cluster="CA"; default_tenant="${VA}";;
    b|cb|2|standby|s) cluster="CB"; default_tenant="${VB}";;
    *) echo "Invalid side. Aborting."; return 0;;
  esac
  echo -n "Tenant (e.g., system, ${default_tenant}, ${default_tenant}-readonly; aliases: crla/crlb) [default ${default_tenant}]: "
  read -r tenant_in; tenant_in="${tenant_in:-$default_tenant}"
  local tenant; tenant="$(_map_tenant_alias "$tenant_in")"
  echo -n "User [default root]: "
  read -r user; user="${user:-root}"
  echo -n "Node ordinal [default 1]: "
  read -r ord; ord="${ord:-1}"
  echo -n "SQL to execute (single line): "
  read -r sql

  _confirm "Execute on ${cluster} | tenant=${tenant} | user=${user} | node=${ord}? [y/N]: " || return 0
  set +e
  run_roach_sql "$cluster" "$sql" "$tenant" "$user" "$ord" "$runtime" || true
  set -e
}

# ===========================
# Status helpers & fallbacks
# ===========================
_status_sql_or_prompt() {
  local cluster="$1" sql="$2" tenant_in="$3" user="${4:-root}"
  local tenant; tenant="$(_map_tenant_alias "$tenant_in")"
  set +e
  run_roach_sql "$cluster" "$sql" "$tenant" "$user"
  local rc=$?
  set -e
  (( rc != 0 )) && echo -e "\nA SQL status check failed (cluster=$cluster, tenant=$tenant). Returning to menu."
  return 0
}

_fetch_shared_vc_names() {
  local cluster_arg="${1:?}" runtime_arg="${2:-}"
  local runtime role
  if [[ -n "$runtime_arg" ]]; then runtime="$runtime_arg"
  elif [[ -n "${docker_command:-}" ]]; then runtime="${docker_command}"
  elif [[ -n "${DOCKER_CMD:-}" ]]; then runtime="${DOCKER_CMD}"
  else runtime="$(_default_runtime)"; fi
  role="$(_canon_cluster "$cluster_arg" 2>/dev/null || echo "$cluster_arg")"
  if _is_dry; then echo ""; return; fi

  local low high
  case "${role,,}" in ca) low=26000; high=27000 ;; cb) low=27000; high=28000 ;; *) echo "ERR: bad role" >&2; return 1 ;; esac
  local node names; names="$(_get_names_by_role "$runtime" "$role")"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && { echo ""; return 0; }

  local csql="" line cport
  while IFS= read -r line; do
    cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue
    if (( cport >= low && cport < high )); then csql="$cport"; break; fi
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && { echo ""; return 0; }

  local url="postgresql://root@${node}:${csql}?options=-ccluster=system&sslmode=disable"
  local out
  out="$($runtime exec -i "$node" ./cockroach sql --format=tsv --insecure --url "$url" --execute "SHOW VIRTUAL CLUSTERS;" 2>/dev/null || true)"

  local shared=()
  while IFS=$'\t' read -r cid cname _ cmode; do
    [[ -z "$cid" || "$cid" == "id" ]] && continue
    [[ "$cmode" == "shared" ]] && shared+=("$cname")
  done <<< "$out"
  (IFS=$'\n'; printf "%s\n" "${shared[@]:-}")
}

_tenant_is_shared() {
  local cluster="${1:?}" tenant_in="${2:?}"; local tenant; tenant="$(_map_tenant_alias "$tenant_in")"
  local shared; shared="$(_fetch_shared_vc_names "$cluster")"
  grep -Fxq "$tenant" <<< "$shared"
}

_role_node_and_sqlport() {
  local runtime="${1:?}" role_in="${2:?}"
  local role; role="$(_canon_cluster "$role_in" 2>/dev/null || echo "$role_in")"
  local names node; names="$(_get_names_by_role "$runtime" "$role")"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && return 1
  local csql="" line cport low high
  case "$role" in CA) low=26000; high=27000 ;; CB) low=27000; high=28000 ;; *) return 1 ;; esac
  while IFS= read -r line; do
    cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue
    if (( cport >= low && cport < high )); then csql="$cport"; break; fi
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && return 1
  echo "$node $csql"
}

_count_movr_with_fallback() {
  local cluster="${1:?CA|CB|primary|standby}" pref_tenant_in="${2:?}" alt_tenant_in="${3:-}" runtime="${4:-$(_default_runtime)}"
  local pref_tenant; pref_tenant="$(_map_tenant_alias "$pref_tenant_in")"
  local alt_tenant; alt_tenant="$(_map_tenant_alias "$alt_tenant_in")"
  set +e
  run_roach_sql "$cluster" "SELECT count(*) FROM movr.users;" "$pref_tenant" root 1 "$runtime"
  local rc=$?
  set -e
  (( rc == 0 )) && return 0
  [[ -z "$alt_tenant" ]] && return 1

  if _is_dry; then
    if _tenant_is_shared "$cluster" "$alt_tenant"; then
      _printc "$CYAN_BOLD" "(DRY-RUN) Falling back to ${alt_tenant} (shared) for movr.users count..."
      run_roach_sql "$cluster" "SELECT count(*) FROM movr.users;" "$alt_tenant" root 1 "$runtime" || true
    fi
    return 0
  fi

  local role node csql
  role="$(_canon_cluster "$cluster" 2>/dev/null || echo "$cluster")"
  read -r node csql < <(_role_node_and_sqlport "$runtime" "$role") || return 1
  local url="postgresql://root@${node}:${csql}?options=-ccluster=${pref_tenant}&sslmode=disable"
  local out
  out="$($runtime exec -i "$node" ./cockroach sql --format=tsv --insecure --url "$url" --execute "SELECT count(*) FROM movr.users;" 2>&1 || true)"
  if grep -q "service unavailable for target tenant (${pref_tenant})" <<< "$out"; then
    if _tenant_is_shared "$cluster" "$alt_tenant"; then
      _printc "$CYAN_BOLD" "Attempt on ${pref_tenant} failed. Retrying on '${alt_tenant}' (shared)..."
      set +e
      run_roach_sql "$cluster" "SELECT count(*) FROM movr.users;" "$alt_tenant" root 1 "$runtime"
      set -e
      return 0
    fi
  fi
  return 1
}

# ===========================
# Cluster status
# ===========================
status_roach_clusters() {
  heading "Status" "Containers • Ports • VCs"

  local runtime_arg="${1:-}"
  local runtime
  if [[ -n "$runtime_arg" ]]; then runtime="$runtime_arg"
  elif [[ -n "${docker_command:-}" ]]; then runtime="${docker_command}"
  elif [[ -n "${DOCKER_CMD:-}" ]]; then runtime="${DOCKER_CMD}"
  else runtime="$(_default_runtime)"; fi

  if _is_dry; then
    _printc "$CYAN_BOLD" "=== (DRY-RUN) Status: would inspect containers and run VCs/DBs & movr.users (with readonly logic) ==="
    return
  fi

  _printc "$YELLOW_BOLD" "CA (on roachnet1):"
  local pnames; pnames="$(_get_names_by_role "$runtime" CA)"
  if [[ -z "$pnames" ]]; then _printc "$YELLOW_BOLD" "  (none)"
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local state http_port="" sql_port=""
      state=$($runtime inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "?")
      while IFS= read -r line; do
        local cport="${line%%/*}"; local hport="${line##*:}"
        [[ "$cport" =~ ^[0-9]+$ ]] || continue
        [[ "$hport" =~ ^[0-9]+$ ]] || continue
        (( cport >= 8000 && cport < 9000 ))  && http_port="$hport"
        (( cport >= 26000 && cport < 27000 )) && sql_port="$hport"
      done <<< "$($runtime port "$name" 2>/dev/null || true)"
      local http_display="-"; [[ -n "$http_port" ]] && http_display="http://localhost:${http_port}"
      local sql_display="-";  [[ -n "$sql_port"  ]] && sql_display="localhost:${sql_port}"
      _printc "$YELLOW_BOLD" " - ${name} | state: ${state} | Vol: roachvol${name#roach} | HTTP: ${http_display} | SQL: ${sql_display}"
    done <<< "$pnames"
  fi

  _printc "$BLUE_BOLD" "CB (on roachnet1):"
  local snames; snames="$(_get_names_by_role "$runtime" CB)"
  if [[ -z "$snames" ]]; then _printc "$BLUE_BOLD" "  (none)"
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local state http_port="" sql_port=""
      state=$($runtime inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "?")
      while IFS= read -r line; do
        local cport="${line%%/*}"; local hport="${line##*:}"
        [[ "$cport" =~ ^[0-9]+$ ]] || continue
        [[ "$hport" =~ ^[0-9]+$ ]] || continue
        (( cport >= 8000 && cport < 9000 ))  && http_port="$hport"
        (( cport >= 27000 && cport < 28000 )) && sql_port="$hport"
      done <<< "$($runtime port "$name" 2>/dev/null || true)"
      local http_display="-"; [[ -n "$http_port" ]] && http_display="http://localhost:${http_port}"
      local sql_display="-";  [[ -n "$sql_port"  ]] && sql_display="localhost:${sql_port}"
      _printc "$BLUE_BOLD" " - ${name} | state: ${state} | Vol: roachvol${name#roach} | HTTP: ${http_display} | SQL: ${sql_display}"
    done <<< "$snames"
  fi

  echo "   "

  # System tenant checks (both sides)
  _status_sql_or_prompt CA "SHOW VIRTUAL CLUSTERS;" system root
  _status_sql_or_prompt CB "SHOW VIRTUAL CLUSTERS;" system root

  # Pretty replication status
  set +e
  run_roach_sql CA "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" system root || true
  run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root || true
  set -e

  set +e
  run_roach_sql CA "SHOW CLUSTER SETTING server.controller.default_target_cluster;" system root || true
  run_roach_sql CB "SHOW CLUSTER SETTING server.controller.default_target_cluster;" system root || true
  set -e

  # Determine ingesting side
  local pnode pcsql snode scsql
  read -r pnode pcsql < <(_role_node_and_sqlport "$runtime" CA) || true
  read -r snode scsql < <(_role_node_and_sqlport "$runtime" CB) || true
  local ca_sys_url cb_sys_url
  [[ -n "${pnode:-}" && -n "${pcsql:-}" ]] && ca_sys_url="postgresql://root@${pnode}:${pcsql}?${PG_SYSTEM}&sslmode=disable"
  [[ -n "${snode:-}" && -n "${scsql:-}" ]] && cb_sys_url="postgresql://root@${snode}:${scsql}?${PG_SYSTEM}&sslmode=disable"
  local outA outB into_va=0 into_vb=0
  outA="$([[ -n "${ca_sys_url:-}" ]] && $runtime exec -i "$pnode" ./cockroach sql --format=tsv --insecure --url "$ca_sys_url" --execute "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" 2>/dev/null || true)"
  outB="$([[ -n "${cb_sys_url:-}" ]] && $runtime exec -i "$snode" ./cockroach sql --format=tsv --insecure --url "$cb_sys_url" --execute "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" 2>/dev/null || true)"
  grep -iqE $'\treplicating(\t|$)' <<< "$outA" && into_va=1
  grep -iqE $'\treplicating(\t|$)' <<< "$outB" && into_vb=1

  # Tenant DB lists
  _status_sql_or_prompt CA "SHOW DATABASES;" default root
  _status_sql_or_prompt CB "SHOW DATABASES;" default root


  _status_sql_or_prompt CA "SELECT count(*) FROM movr.users;" default root
  _status_sql_or_prompt CB "SELECT count(*) FROM movr.users;" default root

}

# ===========================
# Cleanup helpers
# ===========================
destroy_roach_role_detect() {
  heading "Cleanup (Role)" "Remove selected role's containers & volumes"

  local role_in="${1:?Usage: destroy_roach_role_detect <CA|CB|primary|standby> [runtime] }" runtime_arg="${2:-}"
  local role; role="$(_canon_cluster "$role_in" 2>/dev/null || echo "$role_in")"
  local runtime
  if [[ -n "$runtime_arg" ]]; then runtime="$runtime_arg"
  elif [[ -n "${docker_command:-}" ]]; then runtime="${docker_command}"
  elif [[ -n "${DOCKER_CMD:-}" ]]; then runtime="${DOCKER_CMD}"
  else runtime="$(_default_runtime)"; fi

  if _is_dry; then _printc "$CYAN_BOLD" "[DRY-RUN] Would remove ${role} containers, their roachvol*, and roachnet1 if empty."; return; fi

  local names; names="$(_get_names_by_role "$runtime" "$role")"
  if [[ -z "$names" ]]; then echo "No ${role} containers found on roachnet1."
  else
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local vol="roachvol${name#roach}"
      echo "Removing ${role} container $name..."
      _exec "$runtime" rm -f "$name" >/dev/null 2>&1 || true
      if $runtime volume inspect "$vol" >/dev/null 2>&1; then
        echo "Removing volume $vol..."; _exec "$runtime" volume rm "$vol" >/dev/null 2>&1 || true
      fi
    done <<< "$names"
  fi

  if $runtime network inspect roachnet1 >/dev/null 2>&1; then
    local attached; attached=$($runtime ps -a --filter "network=roachnet1" --format '{{.Names}}' | grep -E '^roach[0-9]+$' || true)
    [[ -z "$attached" ]] && _exec "$runtime" network rm roachnet1 >/dev/null 2>&1 || true
  fi
  echo "${role} cleanup complete."
}

destroy_both_clusters() {
  heading "Cleanup" "Remove clusters A & B"

  local runtime_arg="${1:-}"
  local runtime
  if [[ -n "$runtime_arg" ]]; then runtime="$runtime_arg"
  elif [[ -n "${docker_command:-}" ]]; then runtime="${docker_command}"
  elif [[ -n "${DOCKER_CMD:-}" ]]; then runtime="${DOCKER_CMD}"
  else runtime="$(_default_runtime)"; fi

  if _is_dry; then _printc "$CYAN_BOLD" "[DRY-RUN] Would remove ALL roach* containers, roachnet1, and ALL roachvol* volumes."; return; fi

  echo "Removing ALL roach* containers..."
  local all_names; all_names=$($runtime ps -a --format '{{.Names}}' | grep -E '^roach[0-9]+$' || true)
  if [[ -n "$all_names" ]]; then
    while IFS= read -r name; do [[ -z "$name" ]] && continue; echo "Removing container $name..."; _exec "$runtime" rm -f "$name" >/dev/null 2>&1 || true; done <<< "$all_names"
  else echo "No roach containers found."; fi

  echo "Removing networks..."
  if $runtime network inspect roachnet1 >/dev/null 2>&1; then _exec "$runtime" network rm roachnet1 >/dev/null 2>&1 || true; echo "Removed network roachnet1"; fi
  if $runtime network inspect roachnet2 >/dev/null 2>&1; then _exec "$runtime" network rm roachnet2 >/dev/null 2>&1 || true; echo "Removed legacy network roachnet2"; fi

  echo "Removing ALL roachvol* volumes..."
  local vols; vols=$($runtime volume ls --format '{{.Name}}' | grep -E '^roachvol[0-9]+$' || true)
  if [[ -n "$vols" ]]; then while IFS= read -r v; do [[ -z "$v" ]] && continue; echo "Removing volume $v..."; _exec "$runtime" volume rm "$v" >/dev/null 2>&1 || true; done <<< "$vols"
  else echo "No roachvol* volumes found."; fi
  echo "Complete."
}

# ===========================
# Loaders (va/vb)
# ===========================

load_va_1() {
  heading "Load MOVR on A" "Tenant: va (seed workload)"

  local runtime="${1:-$(_default_runtime)}"
  local sql="CREATE DATABASE IF NOT EXISTS va_db;
             CREATE TABLE IF NOT EXISTS va_db.accounts (
               id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
               name STRING NOT NULL,
               created_at TIMESTAMPTZ NOT NULL DEFAULT now()
             );
             UPSERT INTO va_db.accounts (id,name) VALUES ('00000000-0000-0000-0000-000000000001','seed-va-1');
             SHOW DATABASES;"
  set +e
  run_roach_sql CA "$sql" default root 1 "$runtime" || true

  _printc "$YELLOW_BOLD" "Initializing MOVR on CA/va..."
  local p_node="roach1"
  if ! _is_dry; then
    local p_names; p_names="$(_get_names_by_role "$runtime" CA)"
    p_node="$(echo "$p_names" | sed -n '1p')"
    if [[ -z "$p_node" ]]; then _printc "$RED_BOLD" "No CA node found to run MOVR workload."; set -e; return 1; fi
  fi

  local va_url="postgresql://root@${p_node}:26257?options=-ccluster=${VA}&sslmode=disable"
  local va_url="postgresql://root@${p_node}:26257?sslmode=disable"
  local rc1=0 rc2=0
  if _is_dry; then
    _echo_cmd "$runtime" exec -it "$p_node" ./cockroach workload init movr "$va_url"
    _echo_cmd "$runtime" exec -it "$p_node" ./cockroach workload run movr --duration=10s "$va_url"
  else
    $runtime exec -it "$p_node" ./cockroach workload init movr "$va_url"; rc1=$?
    $runtime exec -it "$p_node" ./cockroach workload run movr --duration=10s "$va_url"; rc2=$?
    if (( rc1 == 0 && rc2 == 0 )); then _state_set LOAD_MOVR_OK 1; fi
  fi

  run_roach_sql CA "SHOW DATABASES;" va root 1 "$runtime" || true
  set -e
}

load_va_2() {
  heading "Load MOVR on A (extra)" "Tenant: va (additional 10s)"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$YELLOW_BOLD" "Running additional MOVR workload on CA/va for 10s..."
  local p_node="roach1"
  if ! _is_dry; then
    local p_names; p_names="$(_get_names_by_role "$runtime" CA)"
    p_node="$(echo "$p_names" | sed -n '1p')"
    if [[ -z "$p_node" ]]; then _printc "$RED_BOLD" "No CA node found to run MOVR workload."; set -e; return 1; fi
  fi
  local va_url="postgresql://root@${p_node}:26257?options=-ccluster=${VA}&sslmode=disable"
  local va_url="postgresql://root@${p_node}:26257?sslmode=disable"
  if _is_dry; then _echo_cmd "$runtime" exec -it "$p_node" ./cockroach workload run movr --duration=10s "$va_url"
  else _exec "$runtime" exec -it "$p_node" ./cockroach workload run movr --duration=10s "$va_url" || true; fi
  run_roach_sql CA "SHOW DATABASES;" va root 1 "$runtime" || true
  set -e
}


load_vb() {
  heading "Load MOVR on B" "Tenant: vb"

  local runtime="${1:-$(_default_runtime)}"
  local sql="CREATE DATABASE IF NOT EXISTS vb_db;
             CREATE TABLE IF NOT EXISTS vb_db.customers (
               id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
               email STRING UNIQUE NOT NULL,
               created_at TIMESTAMPTZ NOT NULL DEFAULT now()
             );
             UPSERT INTO vb_db.customers (id,email) VALUES ('00000000-0000-0000-0000-000000000002','seed@vb.example');
             SHOW DATABASES;"
  set +e
  run_roach_sql CB "$sql" default root 1 "$runtime" || true

  local s_node="roach4"
  if ! _is_dry; then
    local s_names; s_names="$(_get_names_by_role "$runtime" CB)"
    s_node="$(echo "$s_names" | sed -n '1p')"
    if [[ -z "$s_node" ]]; then _printc "$RED_BOLD" "No CB node found to run workload."; set -e; return 1; fi
  fi

  local vb_url="postgresql://root@${s_node}:27257?options=-ccluster=${VB}&sslmode=disable"
  local vb_url="postgresql://root@${s_node}:27257?sslmode=disable"
  _printc "$BLUE_BOLD" "Running Movr workload on CB/${VB} for 10s..."
  local rc1=0
  if _is_dry; then
    _echo_cmd "$runtime" exec -it "$s_node" ./cockroach workload run movr --duration=10s "$vb_url"
  else
    $runtime exec -it "$s_node" ./cockroach workload run movr --duration=10s "$vb_url"; rc1=$?
    if (( rc1 == 0 )); then _state_set LOAD_MOVR_VB_OK 1; fi
  fi

  run_roach_sql CB "SHOW DATABASES;" default root 1 "$runtime" || true
  set -e
}

# Back-compat function aliases
create_primary_cluster() { create_CA_cluster "$@"; }
create_standby_cluster() { create_CB_cluster "$@"; }
load_crla_1() { load_va_1 "$@"; }
load_crla_2() { load_va_2 "$@"; }
load_crlb()   { load_vb   "$@"; }

# ===========================
# Replication / Failover
# ===========================
start_replication_a_to_b() {
  heading "Start Replication" "A → B (va → vb-readonly)"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$PURPLE_BOLD" "=== A → B Start Replication ==="
  local sql="CREATE VIRTUAL CLUSTER ${VB} FROM REPLICATION OF ${VA} ON 'postgresql://root@roach1:26257?${PG_SYSTEM}&sslmode=disable' ${READ_VC};"
  run_roach_sql CB "${sql}" system root 1 "$runtime" || true

  local names node csql line cport
  names="$(_get_names_by_role "$runtime" CB)"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && { _printc "$RED_BOLD" "No CB node found."; set -e; return 1; }
  while IFS= read -r line; do cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue; (( cport >= 27000 && cport < 28000 )) && { csql="$cport"; break; }
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && { _printc "$RED_BOLD" "Could not determine CB SQL container port."; set -e; return 1; }
  local cb_sys_url="postgresql://root@${node}:${csql}?${PG_SYSTEM}&sslmode=disable"

  #_printc "$RED_BOLD" "Polling until 'replicating' and 'ready' for VC='${VB}'..."
local out i
for ((i=1; i<=MAX_ITERS; i++)); do
  _printc "$RED_BOLD" "Polling until 'replicating' and 'ready' for VC='${VB}'..."

  status=$(
    run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root 1 "$runtime" \
      | grep -Eio 'replicating|initializing|paused|error|offline|stopped' | head -n1 || true
  )
  dstate=$(
    run_roach_sql CB "SELECT data_state FROM [SHOW VIRTUAL CLUSTERS] WHERE name = '${VB}-readonly';" system root 1 "$runtime" \
      | grep -Eio 'add|ready|initializing|replicating|offline|error' | head -n1 || true
  )
  _printc "$BLUE_BOLD" "[poll ${i}/${MAX_ITERS}] VC='${VB}' readonly='${VB}-readonly' status=${status:-?} data_state=${dstate:-?}"

  if [[ "${status:-}" == "replicating" && "${dstate:-}" == "ready" ]]; then
    _printc "$CYAN_BOLD" "Replication status is 'replicating' and readonly data_state is 'ready'."
    break
  fi

  sleep "$POLL_INTERVAL"
done
if (( i > MAX_ITERS )); then
  _printc "$RED_BOLD" "Timed out waiting for VC='${VB}' to be 'replicating' AND '${VB}-readonly' to be 'ready' on CB."
  return 1
fi
(( i > MAX_ITERS )) && _printc "$RED_BOLD" "WARNING: status did not reach 'replicating' in time."
  run_roach_sql CB "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true
  run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
  
  _state_set REPL_ATOB_ACTIVE 1; _state_set REPL_BTOA_ACTIVE 0; _state_set FAILOVER_ATOB_DONE 0; _state_set FAILOVER_BTOA_DONE 0;
set -e
  sleep 5
}

start_replication_b_to_a() {
  heading "Start Replication" "B → A (vb → va-readonly)"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$PURPLE_BOLD" "=== B → A Start Replication (on CA/system) ==="
  run_roach_sql CA "ALTER VIRTUAL CLUSTER '${VA}' STOP SERVICE;" system root 1 "$runtime" || true
  run_roach_sql CA "ALTER VIRTUAL CLUSTER '${VA}' START REPLICATION OF '${VB}' ON 'postgresql://root@roach4:27257?${PG_SYSTEM}&sslmode=disable' ${READ_VC} ;" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING server.controller.default_target_cluster = '${VB}';" system root 1 "$runtime" || true
  run_roach_sql CA "SET CLUSTER SETTING server.controller.default_target_cluster = '${VA}-readonly';" system root 1 "$runtime" || true

  local names node csql line cport
  names="$(_get_names_by_role "$runtime" CA)"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && { _printc "$RED_BOLD" "No CA node found."; set -e; return 1; }
  while IFS= read -r line; do cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue; (( cport >= 26000 && cport < 27000 )) && { csql="$cport"; break; }
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && { _printc "$RED_BOLD" "Could not determine CA SQL container port."; set -e; return 1; }
  local ca_sys_url="postgresql://root@${node}:${csql}?${PG_SYSTEM}&sslmode=disable"

  _printc "$YELLOW_BOLD" "Polling until ${VA} status is 'replicating'..."
local out i
for ((i=1; i<=MAX_ITERS; i++)); do
  _printc "$RED_BOLD" "Polling until 'replicating' and 'ready' for VC='${VA}'..."

  status=$(
    run_roach_sql CA "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" system root 1 "$runtime" \
      | grep -Eio 'replicating|initializing|paused|error|offline|stopped' | head -n1 || true
  )
  dstate=$(
    run_roach_sql CA "SELECT data_state FROM [SHOW VIRTUAL CLUSTERS] WHERE name = '${VA}-readonly';" system root 1 "$runtime" \
      | grep -Eio 'add|ready|initializing|replicating|offline|error' | head -n1 || true
  )
  #_printc "$BLUE_BOLD" "[poll ${i}/${MAX_ITERS}] VC='${VA}' readonly='${VA}-readonly' status=${status:-?} data_state=${dstate:-?}"
  _printc "$BLUE_BOLD" "[poll ${i}/${MAX_ITERS}] VC='${VA}' readonly='${VA}-readonly' status=${status:-?} data_state=${dstate:-?}"

  if [[ "${status:-}" == "replicating" && "${dstate:-}" == "ready" ]]; then
    _printc "$CYAN_BOLD" "Replication status is 'replicating' and readonly data_state is 'ready'."
    break
  fi

  sleep "$POLL_INTERVAL"
done
if (( i > MAX_ITERS )); then
  _printc "$RED_BOLD" "Timed out waiting for VC='${VA}' to be 'replicating' AND '${VA}-readonly' to be 'ready' on CA."
  return 1
fi
(( i > MAX_ITERS )) && _printc "$RED_BOLD" "WARNING: status did not reach 'replicating' in time."
  run_roach_sql CA "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true
  run_roach_sql CA "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
  
  _state_set REPL_BTOA_ACTIVE 1; _state_set REPL_ATOB_ACTIVE 0; _state_set FAILOVER_ATOB_DONE 0; _state_set FAILOVER_BTOA_DONE 0;
  set -e
  sleep 5
}

failover_a_to_b() {
  heading "Failover" "A → B"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$RED_BOLD" "=== A → B Failover ==="
  run_roach_sql CB "ALTER VIRTUAL CLUSTER '${VB}' COMPLETE REPLICATION TO LATEST;" system root 1 "$runtime" || true

  local names node csql line cport
  names="$(_get_names_by_role "$runtime" CB)"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && { _printc "$RED_BOLD" "No CB node found."; set -e; return 1; }
  while IFS= read -r line; do cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue; (( cport >= 27000 && cport < 28000 )) && { csql="$cport"; break; }
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && { _printc "$RED_BOLD" "Could not determine CB SQL container port."; set -e; return 1; }
  local cb_sys_url="postgresql://root@${node}:${csql}?${PG_SYSTEM}&sslmode=disable"

  _printc "$BLUE_BOLD" "Polling VC='${VB}' until status='ready'..."
  local out i
  for ((i=1; i<=READY_MAX_ITERS; i++)); do
    _printc "$BLUE_BOLD" "$(date) : Iteration ${i}"
    run_roach_sql CB "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true
    run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
    out="$($runtime exec -i "$node" ./cockroach sql --format=tsv --insecure --url "$cb_sys_url" --execute "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" 2>/dev/null || true)"
    if grep -iqE $'\tready(\t|$)' <<< "$out"; then _printc "$BLUE_BOLD" "Status is 'ready'."; break; fi
    sleep "$READY_POLL_INTERVAL"
  done
  (( i > READY_MAX_ITERS )) && _printc "$RED_BOLD" "WARNING: Status did not reach 'ready' in time. Continuing."

  _printc "$BLUE_BOLD" "Starting service (shared) on CB/system (VC='${VB}')..."
  run_roach_sql CB "ALTER VIRTUAL CLUSTER '${VB}' START SERVICE SHARED;" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING server.controller.default_target_cluster = '${VB}';" system root 1 "$runtime" || true
  run_roach_sql CB "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true

  #status_roach_clusters "$runtime"
  
  _state_set FAILOVER_ATOB_DONE 1; _state_set REPL_ATOB_ACTIVE 0;
set -e
}

failover_b_to_a() {
  heading "Failover" "B → A"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$RED_BOLD" "=== B → A Failover ==="

  run_roach_sql CA "ALTER VIRTUAL CLUSTER '${VA}' COMPLETE REPLICATION TO LATEST;" system root 1 "$runtime" || true

  local names node csql line cport
  names="$(_get_names_by_role "$runtime" CA)"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && { _printc "$RED_BOLD" "No CA node found."; set -e; return 1; }
  while IFS= read -r line; do
    cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue
    (( cport >= 26000 && cport < 27000 )) && { csql="$cport"; break; }
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && { _printc "$RED_BOLD" "Could not determine CA SQL container port."; set -e; return 1; }
  local ca_sys_url="postgresql://root@${node}:${csql}?${PG_SYSTEM}&sslmode=disable"

  _printc "$YELLOW_BOLD" "Polling VC='${VA}' until status='ready'..."
  local out i
  for ((i=1; i<=READY_MAX_ITERS; i++)); do
    _printc "$YELLOW_BOLD" "$(date) : Iteration ${i}"
    run_roach_sql CA "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true
    run_roach_sql CA "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
    out="$($runtime exec -i "$node" ./cockroach sql --format=tsv --insecure --url "$ca_sys_url" --execute "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" 2>/dev/null || true)"
    if grep -iqE $'\tready(\t|$)' <<< "$out"; then _printc "$YELLOW_BOLD" "Status is 'ready'."; break; fi
    sleep "$READY_POLL_INTERVAL"
  done
  (( i > READY_MAX_ITERS )) && _printc "$RED_BOLD" "WARNING: Status did not reach 'ready' in time. Continuing."

  _printc "$YELLOW_BOLD" "Starting service (shared) on CA/system (VC='${VA}')..."
  run_roach_sql CA "ALTER VIRTUAL CLUSTER '${VA}' START SERVICE SHARED;" system root 1 "$runtime" || true
  run_roach_sql CA "SET CLUSTER SETTING server.controller.default_target_cluster = '${VA}';" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING server.controller.default_target_cluster = '${VB}';" system root 1 "$runtime" || true
  run_roach_sql CA "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true

  #status_roach_clusters "$runtime"
  
  _state_set FAILOVER_BTOA_DONE 1; _state_set REPL_BTOA_ACTIVE 0;
set -e
}

restart_replication_a_to_b() {
  heading "Start Replication (restart)" "A → B"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$PURPLE_BOLD" "=== A → B ReStart Replication ==="
  run_roach_sql CB "ALTER VIRTUAL CLUSTER ${VB} STOP SERVICE;" system root 1 "$runtime" || true
  run_roach_sql CB "ALTER VIRTUAL CLUSTER ${VB} START REPLICATION OF ${VA} ON 'postgresql://root@roach1:26257?${PG_SYSTEM}&sslmode=disable';" system root 1 "$runtime" || true
  run_roach_sql CA "SET CLUSTER SETTING server.controller.default_target_cluster = '${VA}';" system root 1 "$runtime" || true
  run_roach_sql CB "SET CLUSTER SETTING server.controller.default_target_cluster = '${VB}-readonly';" system root 1 "$runtime" || true

  local names node csql line cport
  names="$(_get_names_by_role "$runtime" CB)"; node="$(echo "$names" | sed -n '1p')"
  [[ -z "$node" ]] && { _printc "$RED_BOLD" "No CB node found."; set -e; return 1; }
  while IFS= read -r line; do cport="${line%%/*}"; [[ "$cport" =~ ^[0-9]+$ ]] || continue; (( cport >= 27000 && cport < 28000 )) && { csql="$cport"; break; }
  done <<< "$($runtime port "$node" 2>/dev/null || true)"
  [[ -z "$csql" ]] && { _printc "$RED_BOLD" "Could not determine CB SQL container port."; set -e; return 1; }
  local cb_sys_url="postgresql://root@${node}:${csql}?${PG_SYSTEM}&sslmode=disable"

  #_printc "$RED_BOLD" "Polling until 'replicating' and 'ready' for VC='${VB}'..."
local i status dstate
for ((i=1; i<=MAX_ITERS; i++)); do
  _printc "$RED_BOLD" "Polling until 'replicating' and 'ready' for VC='${VB}'..."

  status=$(
    run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root 1 "$runtime" \
      | grep -Eio 'replicating|initializing|scan' | head -n1 || true
  )
  dstate=$(
    run_roach_sql CB "SELECT data_state FROM [SHOW VIRTUAL CLUSTERS] WHERE name = '${VB}-readonly';" system root 1 "$runtime" \
      | grep -Eio 'ready|initializing|replicating|offline|error' | head -n1 || true
  )

  #_printc "$BLUE_BOLD" "[poll ${i}/${MAX_ITERS}] VC='${VB}' status=${status:-?} readonly='${VB}-readonly' data_state=${dstate:-?}"
  _printc "$BLUE_BOLD" "[poll ${i}/${MAX_ITERS}] VC='${VB}' readonly='${VB}-readonly' status=${status:-?} data_state=${dstate:-?}"

  if [[ "${status:-}" == "replicating" && "${dstate:-}" == "ready" ]]; then
    _printc "$CYAN_BOLD" "Replication status is 'replicating' and readonly data_state is 'ready'."
    break
  fi

  sleep "$POLL_INTERVAL"
done

if (( i > MAX_ITERS )); then
  _printc "$RED_BOLD" "Timed out waiting for VC='${VB}' to be 'replicating' AND '${VB}-readonly' to be 'ready' on CB."
  return 1
fi

  run_roach_sql CB "SHOW VIRTUAL CLUSTERS;" system root 1 "$runtime" || true
  run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
  
  _state_set REPL_ATOB_ACTIVE 1; _state_set REPL_BTOA_ACTIVE 0;
set -e
}


check_replication_health() {

  heading "Health Check" "Counts & replication status"

  local runtime="${1:-$(_default_runtime)}"
  set +e
  _printc "$YELLOW_BOLD" "CA/system → SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS"
  run_roach_sql CA "SHOW VIRTUAL CLUSTER ${VA} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
  _printc "$BLUE_BOLD" "CB/system → SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS"
  run_roach_sql CB "SHOW VIRTUAL CLUSTER ${VB} WITH REPLICATION STATUS;" system root 1 "$runtime" || true
  set -e

  _printc "$CYAN_BOLD" "Saved state file: ${C44_STATE_FILE}"
  [[ -f "$C44_STATE_FILE" ]] && cat "$C44_STATE_FILE" || _printc "$CYAN_BOLD" "(no saved state yet)"

  _count_tbl() {
    local role="$1" tenant="$2" q="$3"
    set +e
    run_roach_sql "$role" "$q" "$tenant" root 1 "$runtime"
    local rc=$?
    set -e
    return "$rc"
  }

  _count_pref_fallback() {
    local label="$1" role="$2" pref_tenant="$3" fallback_tenant="$4" q="$5" color="$6"
    _printc "$color" "$label on $role/$pref_tenant"
    echo ">>>>>>: " "$color" "$label on $role/$pref_tenant/$fallback_tenant:"
    if ! _count_tbl "$role" "$pref_tenant" "$q"; then
      if [[ -n "$fallback_tenant" ]]; then
        _printc "$color" "  (fallback) $label on $role/$fallback_tenant:"
        _count_tbl "$role" "$fallback_tenant" "$q" || true
      fi
    fi
  }

  local movr_q="SELECT count(*) FROM movr.users;"

  if _state_true REPL_ATOB_ACTIVE; then
    _printc "$PURPLE_BOLD" "*** Healthcheck: A → B replication recorded ***"
    _count_pref_fallback "movr.users" CA "${VA}" "" "$movr_q" "$YELLOW_BOLD"
    _count_pref_fallback "movr.users" CB "${VB}-readonly" "${VB}" "$movr_q" "$BLUE_BOLD"

  elif _state_true REPL_BTOA_ACTIVE; then
    _printc "$PURPLE_BOLD" "*** Healthcheck: B → A replication recorded ***"
    _count_pref_fallback "movr.users" CA "${VA}-readonly" "${VA}" "$movr_q" "$YELLOW_BOLD"
    _count_pref_fallback "movr.users" CB "${VB}" "" "$movr_q" "$BLUE_BOLD"

  else
    _printc "$PURPLE_BOLD" "*** Healthcheck: No replication direction saved; running basic summaries ***"
    _status_sql_or_prompt CA "SHOW VIRTUAL CLUSTERS;" system root
    _status_sql_or_prompt CB "SHOW VIRTUAL CLUSTERS;" system root
    _status_sql_or_prompt CA "SHOW DATABASES;" "${VA}" root
    _status_sql_or_prompt CB "SHOW DATABASES;" "${VB}" root
    _count_pref_fallback "movr.users" CA "${VA}" "${VA}-readonly" "$movr_q" "$YELLOW_BOLD"
    _count_pref_fallback "movr.users" CB "${VB}" "${VB}-readonly" "$movr_q" "$BLUE_BOLD"
  fi
}

# ===========================
# DB Console helpers
# ===========================
detect_console_host() {
  # Priority:
  # 1) C44_CONSOLE_IP env var (explicit)
  # 2) Cloud VM metadata endpoints (GCE, AWS, Azure)
  # 3) Fallback: localhost (desktop)
  if [[ -n "${C44_CONSOLE_IP:-}" ]]; then
    echo "${C44_CONSOLE_IP}"; return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    # GCE
    local ip
    ip="$(curl -s -m 1 -H 'Metadata-Flavor: Google' \
      http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null || true)"
    if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
    # AWS
    ip="$(curl -s -m 1 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    if [[ -n "${ip:-}" && "$ip" != "404 - Not Found" ]]; then echo "$ip"; return 0; fi
    # Azure
    ip="$(curl -s -m 1 -H 'Metadata:true' \
      'http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text' 2>/dev/null || true)"
    if [[ -n "${ip:-}" ]]; then echo "$ip"; return 0; fi
  fi
  echo "localhost"
}

_best_http_port_for_role() {
  local runtime="${1:?}" role_in="${2:?}"
  # Iterate nodes for the role (CA/CB) in order; return the first running node's HTTP host port.
  local names; names="$(_get_names_by_role "$runtime" "$role_in")"
  if [[ -z "$names" ]]; then return 1; fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if _is_dry; then
      # In dry-run, assume conventional ports for CA: 8080,8081,8082...; for CB: 8090,8091,8092...
      case "$role_in" in
        CA|ca|a|1|primary|p) echo 8080; return 0 ;;
        CB|cb|b|2|standby|s) echo 8090; return 0 ;;
        *) return 1 ;;
      esac
    fi
    local state; state="$(_exec "$runtime" inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "?")"
    [[ "$state" != "running" ]] && continue
    local line cport hport
    while IFS= read -r line; do
      cport="${line%%/*}"; hport="${line##*:}"
      [[ "$cport" =~ ^[0-9]+$ && "$hport" =~ ^[0-9]+$ ]] || continue
      if (( cport >= 8000 && cport < 9000 )); then
        echo "$hport"; return 0
      fi
    done <<< "$($runtime port "$name" 2>/dev/null || true)"
  done <<< "$names"
  return 1
}


db_console() {
  heading "DB Console" "Open CA & CB first-node consoles"

  # Print & open DB Console URLs for the FIRST node of CA and CB.
  # If the first node is unavailable, fall back to the next available node in that role.
  # Host: external VM IP (cloud) or localhost (desktop).
  local runtime="${1:-$(_default_runtime)}"
  local host; host="$(detect_console_host)"

  local ca_node cb_node ca_port cb_port

  if _is_dry; then
    ca_node="roach1"; cb_node="roach4"
    ca_port=8080; cb_port=8090
  else
    # --- CA: prefer first node, fallback to next available ---
    local ca_names; ca_names="$(_get_names_by_role "$runtime" CA)"
    local _first
    _first="$(echo "$ca_names" | sed -n '1p')"
    if [[ -n "${_first:-}" ]]; then
      # Check if first node is running and has an HTTP port
      local state; state="$($runtime inspect -f '{{.State.Status}}' "$_first" 2>/dev/null || echo "?")"
      if [[ "$state" == "running" ]]; then
        local line cport hport
        while IFS= read -r line; do
          cport="${line%%/*}"; hport="${line##*:}"
          [[ "$cport" =~ ^[0-9]+$ && "$hport" =~ ^[0-9]+$ ]] || continue
          if (( cport >= 8000 && cport < 9000 )); then ca_node="$_first"; ca_port="$hport"; break; fi
        done <<< "$($runtime port "$_first" 2>/dev/null || true)"
      fi
    fi
    # Fallback: iterate remaining CA nodes if first didn't resolve
    if [[ -z "${ca_port:-}" ]]; then
      while IFS= read -r n; do
        [[ -z "$n" || "$n" == "$_first" ]] && continue
        local state2; state2="$($runtime inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo "?")"
        [[ "$state2" != "running" ]] && continue
        local line2 cport2 hport2
        while IFS= read -r line2; do
          cport2="${line2%%/*}"; hport2="${line2##*:}"
          [[ "$cport2" =~ ^[0-9]+$ && "$hport2" =~ ^[0-9]+$ ]] || continue
          if (( cport2 >= 8000 && cport2 < 9000 )); then ca_node="$n"; ca_port="$hport2"; break; fi
        done <<< "$($runtime port "$n" 2>/dev/null || true)"
        [[ -n "${ca_port:-}" ]] && break
      done <<< "$ca_names"
    fi

    # --- CB: prefer first node, fallback to next available ---
    local cb_names; cb_names="$(_get_names_by_role "$runtime" CB)"
    local _first_cb
    _first_cb="$(echo "$cb_names" | sed -n '1p')"
    if [[ -n "${_first_cb:-}" ]]; then
      local state3; state3="$($runtime inspect -f '{{.State.Status}}' "$_first_cb" 2>/dev/null || echo "?")"
      if [[ "$state3" == "running" ]]; then
        local line3 cport3 hport3
        while IFS= read -r line3; do
          cport3="${line3%%/*}"; hport3="${line3##*:}"
          [[ "$cport3" =~ ^[0-9]+$ && "$hport3" =~ ^[0-9]+$ ]] || continue
          if (( cport3 >= 8000 && cport3 < 9000 )); then cb_node="$_first_cb"; cb_port="$hport3"; break; fi
        done <<< "$($runtime port "$_first_cb" 2>/dev/null || true)"
      fi
    fi
    if [[ -z "${cb_port:-}" ]]; then
      while IFS= read -r n2; do
        [[ -z "$n2" || "$n2" == "$_first_cb" ]] && continue
        local state4; state4="$($runtime inspect -f '{{.State.Status}}' "$n2" 2>/dev/null || echo "?")"
        [[ "$state4" != "running" ]] && continue
        local line4 cport4 hport4
        while IFS= read -r line4; do
          cport4="${line4%%/*}"; hport4="${line4##*:}"
          [[ "$cport4" =~ ^[0-9]+$ && "$hport4" =~ ^[0-9]+$ ]] || continue
          if (( cport4 >= 8000 && cport4 < 9000 )); then cb_node="$n2"; cb_port="$hport4"; break; fi
        done <<< "$($runtime port "$n2" 2>/dev/null || true)"
        [[ -n "${cb_port:-}" ]] && break
      done <<< "$cb_names"
    fi
  fi

  echo
  echo

  if [[ -n "${ca_node:-}" && -n "${ca_port:-}" ]]; then
    local url_ca="http://${host}:${ca_port}"
    _printc "$CYAN_BOLD" "DB Console (CA/${ca_node}):"
    _print_clickable_url "$url_ca"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url_ca" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then open "$url_ca" >/dev/null 2>&1 || true
    elif command -v powershell.exe >/dev/null 2>&1; then powershell.exe start "$url_ca" >/dev/null 2>&1 || true
    fi
  else
    _printc "$RED_BOLD" "Could not resolve CA console URL (is the CA cluster running?)."
  fi

  if [[ -n "${cb_node:-}" && -n "${cb_port:-}" ]]; then
    local url_cb="http://${host}:${cb_port}"
    _printc "$CYAN_BOLD" "DB Console (CB/${cb_node}):"
    _print_clickable_url "$url_cb"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url_cb" >/dev/null 2>&1 || true
    elif command -v open >/dev/null 2>&1; then open "$url_cb" >/dev/null 2>&1 || true
    elif command -v powershell.exe >/dev/null 2>&1; then powershell.exe start "$url_cb" >/dev/null 2>&1 || true
    fi
  else
    _printc "$RED_BOLD" "Could not resolve CB console URL (is the CB cluster running?)."
  fi
}


# Print a clickable URL in terminals that support OSC 8 hyperlinks, and always print the plain URL for universal linking.
_print_clickable_url() {
  local url="$1"
  local style="${C44_URL_STYLE:-auto}"  # values: auto|osc8|plain|both
  # Try OSC 8 link when TTY
  if [[ "$style" == "osc8" || "$style" == "both" || "$style" == "auto" ]]; then
    if [[ -t 1 ]]; then printf '\e]8;;%s\a%s\e]8;;\a\n' "$url" "$url"; fi
  fi
  # Always print a plain URL (many terminals auto-link plain http(s) text)
  if [[ "$style" != "osc8" ]]; then echo "$url"; fi
}

settings_colors() {
  while true; do
    echo
    echo "Color output settings:"
    echo "  1) Auto (default; enable if TTY supports color)"
    echo "  2) On   (force color)"
    echo "  3) Off  (disable color)"
    echo "  q) Back"
    echo
    echo "Current: C44_COLOR='${C44_COLOR:-auto}'"
    if _supports_colors; then
      _printc "$GREEN_BOLD" "Terminal appears to support color."
    else
      _printc "$YELLOW_BOLD" "Terminal may not support color (or stdout is not a TTY)."
    fi
    read -rp "Choose an option [1-3 or q]: " ans
    case "$ans" in
      1)
        export C44_COLOR="auto"
        _enable_colors_if_requested
        _printc "$CYAN_BOLD" "Set C44_COLOR=auto"
        ;;
      2)
        export C44_COLOR="1"
        _enable_colors_if_requested
        _printc "$CYAN_BOLD" "Set C44_COLOR=1 (force on)"
        ;;
      3)
        export C44_COLOR="0"
        _enable_colors_if_requested
        _printc "$CYAN_BOLD" "Set C44_COLOR=0 (off)"
        ;;
      q|Q)
        return 0
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
    echo "Preview:"
    echo "${RED_BOLD}RED${RESET} ${GREEN_BOLD}GREEN${RESET} ${YELLOW_BOLD}YELLOW${RESET} ${BLUE_BOLD}BLUE${RESET} ${PURPLE_BOLD}PURPLE${RESET} ${CYAN_BOLD}CYAN${RESET}"
  done
}

# ===========================
# Settings submenu
# ===========================
settings_menu() {
  heading "Settings" "Runtime • Polling • Repo • Version • Colors"

  while true; do
    echo
    _printc "$CYAN_BOLD" "--- Settings ---"
    local display_repo="${IMAGE_REPO:-docker.io/cockroachdb/cockroach}"
    local display_ver="${CRDB_VERSION:-<unset>}"
    local display_rt="$(_default_runtime)"
    echo "Current values:"
    echo "  RUNTIME (in use)=$display_rt  [override='${RUNTIME_OVERRIDE:-<none>}']"
    echo "  IMAGE_REPO=$display_repo"
    echo "  CRDB_VERSION=$display_ver (used if you leave version blank when creating clusters)"
    echo "  MAX_ITERS=$MAX_ITERS"
    echo "  POLL_INTERVAL=$POLL_INTERVAL (sec)"
    echo "  READY_MAX_ITERS=$READY_MAX_ITERS"
    echo "  READY_POLL_INTERVAL=$READY_POLL_INTERVAL (sec)"
    echo "  INIT_MAX_ITERS=$INIT_MAX_ITERS"
    echo "  INIT_INTERVAL=$INIT_INTERVAL (sec)"
    echo "  DRY_RUN=$DRY_RUN"
    echo "  DEBUG=$DEBUG"
    echo
    echo "1) Set MAX_ITERS"
    echo "2) Set POLL_INTERVAL (sec)"
    echo "3) Set READY_MAX_ITERS"
    echo "4) Set READY_POLL_INTERVAL (sec)"
    echo "5) Set INIT_MAX_ITERS"
    echo "6) Set INIT_INTERVAL (sec)"
    echo "7) Toggle DRY_RUN"
    echo "8) Set Container Runtime (podman/docker/custom)"
    echo "9) Set Default Image Repo"
    echo "10) Set Default Image Version (blank to unset → latest)"
    echo "11) Toggle DEBUG"
    echo "12) Color output (auto/on/off)"
    echo "b) Back"
    echo -n "Choose: "
    read -r sm
    case "$sm" in
      1) echo -n "New MAX_ITERS (current $MAX_ITERS): "; read -r v; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && MAX_ITERS="${v:-$MAX_ITERS}" || echo "Invalid integer."; ;;
      2) echo -n "New POLL_INTERVAL (sec, current $POLL_INTERVAL): "; read -r v; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && POLL_INTERVAL="${v:-$POLL_INTERVAL}" || echo "Invalid integer."; ;;
      3) echo -n "New READY_MAX_ITERS (current $READY_MAX_ITERS): "; read -r v; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && READY_MAX_ITERS="${v:-$READY_MAX_ITERS}" || echo "Invalid integer."; ;;
      4) echo -n "New READY_POLL_INTERVAL (sec, current $READY_POLL_INTERVAL): "; read -r v; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && READY_POLL_INTERVAL="${v:-$READY_POLL_INTERVAL}" || echo "Invalid integer."; ;;
      5) echo -n "New INIT_MAX_ITERS (current $INIT_MAX_ITERS): "; read -r v; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && INIT_MAX_ITERS="${v:-$INIT_MAX_ITERS}" || echo "Invalid integer."; ;;
      6) echo -n "New INIT_INTERVAL (sec, current $INIT_INTERVAL): "; read -r v; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] && INIT_INTERVAL="${v:-$INIT_INTERVAL}" || echo "Invalid integer."; ;;
      7) if [[ "$DRY_RUN" == "1" ]]; then DRY_RUN=0; echo "DRY_RUN disabled."; else DRY_RUN=1; echo "DRY_RUN enabled."; fi ;;
      8)
        echo -n "Enter container runtime (e.g., podman, docker, nerdctl) or blank to clear override: "
        read -r newrt
        if [[ -z "$newrt" ]]; then
          RUNTIME_OVERRIDE=""
          echo "Runtime override cleared. Using: $(_default_runtime)"
        else
          if command -v "$newrt" >/dev/null 2>&1; then
            RUNTIME_OVERRIDE="$newrt"
            echo "Runtime set to '$RUNTIME_OVERRIDE'."
          else
            echo "Command '$newrt' not found on PATH; runtime unchanged."
          fi
        fi
        ;;
      9)
        echo -n "New IMAGE_REPO (current '${IMAGE_REPO:-docker.io/cockroachdb/cockroach}'): "
        read -r repo
        if [[ -n "$repo" ]]; then IMAGE_REPO="$repo"; echo "IMAGE_REPO set to '$IMAGE_REPO'."
        else echo "IMAGE_REPO unchanged."; fi
        ;;
      10)
        echo -n "New default image version (e.g., 24.1.17) or blank to unset (use latest): "
        read -r ver
        if [[ -z "$ver" ]]; then unset -v CRDB_VERSION || true; echo "CRDB_VERSION unset (will use 'latest')."
        else CRDB_VERSION="$ver"; echo "CRDB_VERSION set to '$CRDB_VERSION'."; fi
        ;;
      11)
        if [[ "$DEBUG" == "1" ]]; then DEBUG=0; echo "DEBUG disabled."; else DEBUG=1; echo "DEBUG enabled."; fi
        ;;
      b|B) break ;;
      *) echo "Invalid choice." ;;
    esac
  done
}


# ===========================
# Run All (automated end-to-end)
# ===========================
run_all() {
  heading "Run All" "Full A⇄⇄⇄B DR flow (cleanup → status)"

  # Sequence:
  # 0) Cleanup BOTH clusters
  # 1) Create CA (defaults)
  # 2) Create CB (defaults)
  # 3) load va-1
  # 4) A → B start replication
  # 5) A → B failover
  # 6) load vb
  # 7) B → A start replication
  # 8) B → A failover
  # 9) Load va-2
  # 11) Check replication health
  local runtime="$(_default_runtime)"
  local n=3
  local ver="${CRDB_VERSION:-}"
  local current_step=""
  set -e
  trap 'rc=$?; set +e; _printc "$RED_BOLD" "❌ Run All failed at step: ${current_step} (exit $rc)"; return $rc' ERR

  current_step="Cleanup BOTH clusters"
  destroy_both_clusters "$runtime"

  current_step="Create CA cluster (n=${n}, ver=${ver:-latest})"
  create_CA_cluster "$n" "$runtime" "${ver}"

  current_step="Create CB cluster (n=${n}, ver=${ver:-latest})"
  create_CB_cluster "$n" "$runtime" "${ver}"

  current_step="Load MOVR on CA/va (load_va_1)"
  load_va_1 "$runtime"

  current_step="Start A → B replication"
  start_replication_a_to_b "$runtime"

  current_step="A → B failover"
  failover_a_to_b "$runtime"

  current_step="Load MOVR on CB/vb (load_vb)"
  load_vb "$runtime"

  current_step="Start B → A replication"
  start_replication_b_to_a "$runtime"

  sleep 30
  current_step="B → A failover"
  failover_b_to_a "$runtime"

  current_step="Load MOVR on CA/va (load_va_2)"
  load_va_2 "$runtime"

  current_step="Check replication health"
  status_roach_clusters "$runtime"

  current_step="A → B restart replication"
  restart_replication_a_to_b "$runtime"

  current_step="Check replication health"
  status_roach_clusters "$runtime"

  set +e
  _printc "$GREEN_BOLD" "✅ Run All completed successfully."
  trap - ERR
}

# ===========================
# Headings (multi-line)
# ===========================
: "${C44_HEADING_STYLE:=thick}"   # box | thick | ascii | rule
: "${C44_HEADING_WIDTH:=0}"     # 0 = auto (terminal width), or force e.g. 72

_h_cols() { tput cols 2>/dev/null || echo 80; }
_h_width() { [[ "${C44_HEADING_WIDTH}" -gt 0 ]] && echo "${C44_HEADING_WIDTH}" || _h_cols; }
_h_fill() { local n="$1" ch="$2"; printf "%*s" "$n" "" | tr " " "$ch"; }

_heading_box() { # box, centered title + optional subtitle
  local title="$1" subtitle="$2"
  local W; W=$(_h_width)
  local top="╔$(_h_fill $((W-2)) "═")╗"
  local mid="║$(_h_fill $((W-2)) " ")║"
  local bot="╚$(_h_fill $((W-2)) "═")╝"
  local pt=" $title "
  local st; [[ -n "$subtitle" ]] && st=" $subtitle "
  local len_t=${#pt}
  local pad_l=$(( (W-2-len_t)/2 )); (( pad_l<0 )) && pad_l=0
  local pad_r=$(( (W-2-len_t)-pad_l )); (( pad_r<0 )) && pad_r=0
  echo "${PURPLE_BOLD}${top}${RESET}"
  echo "║$(_h_fill $pad_l " ")${GREEN_BOLD}${pt}${RESET}$(_h_fill $pad_r " ")║"
  if [[ -n "$subtitle" ]]; then
    local avail=$((W-4)); [[ ${#st} -gt $avail ]] && st="${st:0:avail}…"
    echo "${CYAN_BOLD}║ ${st}$(_h_fill $((W-3-${#st})) " ")║${RESET}"
  else
    echo "${mid}"
  fi
  echo "${bot}"
  echo
}

_heading_thick() { # double-line heavy box
  local title="$1" subtitle="$2"
  local W; W=$(_h_width)
  local top="╔$(_h_fill $((W-2)) "═")╗"
  local bar="╠$(_h_fill $((W-2)) "═")╣"
  local bot="╚$(_h_fill $((W-2)) "═")╝"
  echo "${BLUE_BOLD}${top}${RESET}"
  printf "║ %s%s\n" "${YELLOW_BOLD}${title}${RESET}" "$(_h_fill $((W-3-${#title})) " ")│" | sed "s/│$/${RESET}║/"
  echo "${bar}"
  if [[ -n "$subtitle" ]]; then
    printf "║ %s%s\n" "${CYAN_BOLD}${subtitle}${RESET}" "$(_h_fill $((W-3-${#subtitle})) " ")│" | sed "s/│$/${RESET}║/"
  else
    printf "║ %s%s\n" "" "$(_h_fill $((W-3)) " ")│" | sed "s/│$/${RESET}║/"
  fi
  echo "${bot}"
  echo
}

_heading_ascii() { # plain ASCII banner
  local title="$1" subtitle="$2"
  local W; W=$(_h_width)
  local hr=\"+$(_h_fill $((W-2)) '-')+\"
  echo "${hr}"
  printf "| %s%s\n" "${title}" "$(_h_fill $((W-3-${#title})) " ")|"
  if [[ -n "$subtitle" ]]; then
    echo "| $subtitle$(_h_fill $((W-3-${#subtitle})) " ")|"
  else
    echo "| $(_h_fill $((W-3)) " ")|"
  fi
  echo "${hr}"
  echo
}

_heading_rule() { # rule + title
  local title="$1" subtitle="$2"
  local W; W=$(_h_width)
  printf "%s\n" "${GREEN_BOLD}$(_h_fill "$W" "=")${RESET}"
  printf "%s\n" "${YELLOW_BOLD}${title}${RESET}"
  [[ -n "$subtitle" ]] && printf "%s\n" "${CYAN_BOLD}${subtitle}${RESET}"
  printf "%s\n\n" "$(_h_fill "$W" "-")"
}

heading() { # heading "Title" ["Subtitle"]
  local title="$1" subtitle="$2"
  case "${C44_HEADING_STYLE}" in
    box)   _heading_box   "$title" "$subtitle" ;;
    thick) _heading_thick "$title" "$subtitle" ;;
    ascii) _heading_ascii "$title" "$subtitle" ;;
    rule|*)_heading_rule  "$title" "$subtitle" ;;
  esac
}

# ===========================
# Return <table> row count for default tenant on a given side (CA|CB)
_count_movr_users() {
  local side="${1:?CA|CB}"
  local runtime="${2:-$(_default_runtime)}"
  local table="${3:-movr.users}"
  [[ "$table" =~ ^[A-Za-z0-9_.]+$ ]] || table="movr.users"

  local role; role="$(_canon_cluster "$side" 2>/dev/null || echo "$side")"
  local names node
  if _is_dry; then
    node=$([[ "$role" == "CA" ]] && echo "roach1" || echo "roach4")
  else
    names="$(_get_names_by_role "$runtime" "$role")"
    node="$(echo "$names" | sed -n '1p')"
    [[ -z "${node:-}" ]] && { echo ""; return 1; }
  fi

  local base_sql
  case "$role" in
    CA) base_sql=26257 ;;
    CB) base_sql=27257 ;;
    *)  echo ""; return 1 ;;
  esac

  local url="postgresql://root@${node}:${base_sql}"
  ${runtime} exec -i "${node}" ./cockroach sql --format=tsv --insecure --url "${url}" \
    --execute "SELECT count(*) FROM ${table};" 2>/dev/null | awk 'NR==2{print $1}'
}

check_row_counts() {
local table="${1:-movr.users}"
local runtime="${RUNTIME_OVERRIDE:-$(_default_runtime)}"
heading "Check Row Counts" "${table} on default tenants (CA & CB)"
local ca cb

while :; do
  ca="$(_count_movr_users CA "$runtime" "$table")"
  cb="$(_count_movr_users CB "$runtime" "$table")"

  if [[ "${ca:-}" =~ ^[0-9]+$ && "${cb:-}" =~ ^[0-9]+$ ]]; then
    if (( ca == cb )); then
      _printc "$GREEN_BOLD" "CA(default)=${ca}  CB(default)=${cb}  ✓ match"
      _printc "$GREEN_BOLD" "Row counts match across clusters: ${ca}"
      return 0
    else
      _printc "$YELLOW_BOLD" "CA(default)=${ca}  CB(default)=${cb}  … mismatch"
    fi
  else
    _printc "$YELLOW_BOLD" "CA(default)=${ca:-?}  CB(default)=${cb:-?}  … waiting (non-numeric)"
  fi

  # Ask user whether to keep monitoring for up to 60 seconds (5s cadence), or quit to menu
  if type _confirm >/dev/null 2>&1; then
    if _confirm "Keep monitoring for up to 60s (checks every 5s)? (y=continue, n=quit)"; then
      _printc "$BLUE_BOLD" "Monitoring for up to 60 seconds..."
    else
      _printc "$YELLOW_BOLD" "Returning to menu without matched row counts. Final: CA=${ca:-?}, CB=${cb:-?}"
      return 0
    fi
  else
    read -r -p "Keep monitoring for up to 60s (5s cadence)? [Y/n] " ans
    ans="${ans:-Y}"; ans="$(_lower "$ans" 2>/dev/null || printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "$ans" =~ ^y ]]; then
      _printc "$YELLOW_BOLD" "Returning to menu without matched row counts. Final: CA=${ca:-?}, CB=${cb:-?}"
      return 0
    fi
    _printc "$BLUE_BOLD" "Monitoring for up to 60 seconds..."
  fi

  # 12 quick checks (5s each) or until matched
  local j
  for ((j=1; j<=12; j++)); do
    sleep 5
    ca="$(_count_movr_users CA "$runtime" "$table")"
    cb="$(_count_movr_users CB "$runtime" "$table")"
    if [[ "${ca:-}" =~ ^[0-9]+$ && "${cb:-}" =~ ^[0-9]+$ && ca -eq cb ]]; then
      _printc "$GREEN_BOLD" "[watch ${j}/12] CA(default)=${ca}  CB(default)=${cb}  ✓ match"
      _printc "$GREEN_BOLD" "Row counts match across clusters: ${ca}"
      return 0
    else
      _printc "$YELLOW_BOLD" "[watch ${j}/12] CA(default)=${ca:-?}  CB(default)=${cb:-?}  … waiting"
    fi
  done
  # After 60s window, loop back to ask again.
done
}

# Menu
# ===========================
pcr_menu() {
while true; do
    echo
    _printc "$CYAN_BOLD" "=== CockroachDB Menu (single network: roachnet1) ==="
    if _is_dry; then _printc "$CYAN_BOLD" "*** DRY-RUN MODE: Commands will be printed but not executed ***"; fi
    echo "0)  Cleanup"
    echo "1)  Create CA-va"
    echo "2)  Create CB-vb"
    echo "3)  Load va-1"
    echo "4)  A --> B Start Replication"
    echo "5)  A --> B Failover"
    echo "6)  Load vb"
    echo "7)  B --> A Start Replication"
    echo "8)  B --> A Failover"
    echo "9)  Load va-2"
    echo "10) A --> B  Restart Replication"
    echo "11) Check replication health"
    echo "12) Check row counts"
    echo "13) Run All"
    echo "14) Run ad-hoc SQL"
    echo "15) DB Console"
    echo "16) Settings"
    echo "q)  Quit"
    echo -n "Select an option [0-16 or q]: "
    read -r choice || exit 0
    case "$choice" in
      0)
        echo "Cleanup options:"
        echo "  1) Remove CA only"
        echo "  2) Remove CB only"
        echo "  3) Remove BOTH (all roach* containers, all roachvol* volumes, roachnet1)"
        echo -n "Choose [1-3]: "; read -r c
        case "$c" in
          1) _confirm "Remove CA (containers + volumes)? [y/N]: " && destroy_roach_role_detect CA "$(_default_runtime)";;
          2) _confirm "Remove CB (containers + volumes)? [y/N]: " && destroy_roach_role_detect CB "$(_default_runtime)";;
          3) _confirm "Remove BOTH clusters, ALL roachvol*, and network roachnet1? [y/N]: " && destroy_both_clusters "$(_default_runtime)";;
          *) echo "Invalid cleanup option." ;;
        esac
        ;;
      1)
        echo -n "Number of nodes for CA (default 3): "; read -r n; n="${n:-3}"
        echo -n "Image version (e.g., 24.1.17) or empty for default (${CRDB_VERSION:-latest}): "; read -r ver; ver="${ver:-}"
        _confirm "Create CA with n=${n}, version='${ver:-${CRDB_VERSION:-latest}}'? [y/N]: " && create_CA_cluster "$n" "$(_default_runtime)" "${ver}"
        ;;
      2)
        echo -n "Number of nodes for CB (default 3): "; read -r n; n="${n:-3}"
        echo -n "Image version (e.g., 24.1.17) or empty for default (${CRDB_VERSION:-latest}): "; read -r ver; ver="${ver:-}"
        _confirm "Create CB with n=${n}, version='${ver:-${CRDB_VERSION:-latest}}'? [y/N]: " && create_CB_cluster "$n" "$(_default_runtime)" "${ver}"
        ;;
      3) _confirm "Run initial MOVR load on CA/va for 10s? [y/N]: " && load_va_1 "$(_default_runtime)" ;;
      4) _confirm "Start Replication A → B now? [y/N]: "              && start_replication_a_to_b "$(_default_runtime)" ;;
      5) _confirm "Failover A → B now? [y/N]: "                       && failover_a_to_b "$(_default_runtime)" ;;
      6) _confirm "Run MOVR load on CB/vb for ~10s? [y/N]: "          && load_vb "$(_default_runtime)" ;;
      7) _confirm "Start Replication B → A now? [y/N]: "              && start_replication_b_to_a "$(_default_runtime)" ;;
      8) _confirm "Failover B → A now? [y/N]: "                       && failover_b_to_a "$(_default_runtime)" ;;
      9) _confirm "Run additional MOVR load on CA/va for 10s? [y/N]: " && load_va_2 "$(_default_runtime)" ;;
      10) _confirm "A → Restart Replication now? [y/N]: "             && restart_replication_a_to_b "$(_default_runtime)" ;;
      11) status_roach_clusters "$(_default_runtime)" ;;
      13) run_all ;;
      14) run_sql_interactive "$(_default_runtime)" ;;
      15) db_console "$(_default_runtime)" ;;
      16) settings_menu ;;
      q|Q) _confirm "Are you sure you want to quit? [y/N]: " && { echo "Goodbye!"; break; } ;;
      12) check_row_counts ;;

      *) echo "Invalid option." ;;
    esac
  done


}

# Smoke test for tenant=default URL path
pcr_smoke_default() {
  local runtime="${RUNTIME_OVERRIDE:-$(_default_runtime)}"
  _printc "$CYAN_BOLD" "[smoke-default] Validating tenant=default connection path"
  local rc=0

  _printc "$BLUE_BOLD" "-> CA node1: SELECT 1"
  if run_roach_sql CA "SELECT 1;" default root 1 "$runtime"; then
    _printc "$CYAN_BOLD" "CA: OK"
  else
    _printc "$RED_BOLD" "CA: FAILED"
    rc=1
  fi

  _printc "$BLUE_BOLD" "-> CB node1: SELECT 1"
  if run_roach_sql CB "SELECT 1;" default root 1 "$runtime"; then
    _printc "$CYAN_BOLD" "CB: OK"
  else
    _printc "$RED_BOLD" "CB: FAILED"
    rc=1
  fi
  return "$rc"
}

# Entry point
if [[ "${MODE:-}" == "menu" || "${1:-}" == "menu" ]]; then
  pcr_menu
fi

if [[ "${MODE:-}" == "smoke-default" || "${1:-}" == "smoke-default" ]]; then
  if pcr_smoke_default; then
    _printc "$CYAN_BOLD" "[smoke-default] Success"
    exit 0
  else
    _printc "$RED_BOLD" "[smoke-default] Failure"
    exit 1
  fi
fi
