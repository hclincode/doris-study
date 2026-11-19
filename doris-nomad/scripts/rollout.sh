#!/usr/bin/env bash
# Rolling upgrade / config change of Doris on Nomad.
#
#   scripts/rollout.sh --mode server   # at most ONE server down in the whole cluster
#   scripts/rollout.sh --mode group    # at most ONE server group down (whole group at once)
#
# Options:
#   --component be|fe|all   (default all: BE groups first, then FE, master FE last)
#   --groups "dc1 dc2 dc3"  (order for BE; FE order is computed: non-master first)
#   --plan                  only run nomad-pack plan for every job, change nothing
#   --var k=v               extra nomad-pack variable, may repeat (e.g. --var be_image=...)
#
# Guarantees (enforced here, not by luck):
#   * one job (= one server group of one component) is changed at a time;
#   * the next job starts only after the previous deployment is successful AND the
#     Doris cluster is healthy again (all BEs/FEs alive, zero unhealthy tablets);
#   * inside a job, max_parallel = 1 (server) or = be_count (group).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

MODE=""; COMPONENT=all; PLAN=0; EXTRA=()
while (($#)); do
  case "$1" in
    --mode) MODE=$2; shift 2 ;;
    --component) COMPONENT=$2; shift 2 ;;
    --groups) DORIS_GROUPS=$2; read -r -a GROUPS_ARR <<<"$DORIS_GROUPS"; shift 2 ;;
    --plan) PLAN=1; shift ;;
    --var) EXTRA+=(--var "$2"); shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ "$MODE" == server || "$MODE" == group ]] || die "--mode server|group is required"
[[ "$COMPONENT" =~ ^(be|fe|all)$ ]] || die "--component be|fe|all"

group_be_count() { awk -F= '/^[[:space:]]*be_count/ {gsub(/[[:space:]]/,"",$2); print $2}' "$VARS_DIR/$1.hcl"; }

cluster_healthy() { backends_all_alive && frontends_ok && tablets_healthy; }
group_has() { [[ "$(backends_in_group "$1")" -ge "$2" ]]; }

# ---------------------------------------------------------------- plan only
if ((PLAN)); then
  for c in be fe; do
    [[ "$COMPONENT" == all || "$COMPONENT" == "$c" ]] || continue
    for g in "${GROUPS_ARR[@]}"; do
      log "plan $(job_name "$c" "$g")"; pack_plan "$c" "$g" "$MODE" "${EXTRA[@]}"
    done
  done
  exit 0
fi

# ---------------------------------------------------------------- pre-flight
log "pre-flight: mode=$MODE component=$COMPONENT groups=${GROUPS_ARR[*]}"
no_active_deployments || die "finish or fail the active deployment first"
if [[ -f "${ROLLOUT_STATE_FILE:-$ROOT/.rollout-orig-fe-config}" ]]; then
  log "previous rollout did not finish: letting Doris repair replicas before continuing"
  wait_for "all BEs alive" backends_all_alive
  fe_cfg_set disable_tablet_scheduler false
  wait_for "zero unhealthy tablets" tablets_healthy
fi
cluster_healthy || die "cluster is not healthy (dead BE/FE or unhealthy tablets); refusing to take anything down"
for g in "${GROUPS_ARR[@]}"; do
  n=$(backends_in_group "$g"); want=$(group_be_count "$g")
  [[ "$n" -ge "$want" ]] || die "group $g: only $n alive BEs tagged $g, expected $want"
done

KEYS=(disable_balance disable_colocate_balance disable_tablet_scheduler)
STATE_FILE=${ROLLOUT_STATE_FILE:-$ROOT/.rollout-orig-fe-config}
declare -A ORIG
if [[ -f "$STATE_FILE" ]]; then
  # A previous run stopped half way and left repair/balance disabled: keep the TRUE originals.
  log "resuming: original FE config read from $STATE_FILE"
  while IFS='=' read -r k v; do ORIG[$k]=$v; done <"$STATE_FILE"
else
  : >"$STATE_FILE"
  for k in "${KEYS[@]}"; do ORIG[$k]=$(fe_cfg_get "$k"); echo "$k=${ORIG[$k]}" >>"$STATE_FILE"; done
fi
restore() {
  for k in "${KEYS[@]}"; do fe_cfg_set "$k" "${ORIG[$k]:-false}" || true; done
  rm -f "$STATE_FILE"
}
on_error() {
  log "!!! rollout stopped. Balance/repair stay DISABLED on purpose while a group may be degraded."
  log "!!! fix the cause, then re-run this script (it is idempotent), or restore manually:"
  for k in "${KEYS[@]}"; do log "!!!   ADMIN SET FRONTEND CONFIG (\"$k\" = \"${ORIG[$k]:-false}\");"; done
}
trap on_error ERR

# Doris upgrade rule: turn off replica repair + balance while nodes restart.
for k in "${KEYS[@]}"; do fe_cfg_set "$k" true; done

# ---------------------------------------------------------------- BE: one group at a time
if [[ "$COMPONENT" == all || "$COMPONENT" == be ]]; then
  for g in "${GROUPS_ARR[@]}"; do
    deploy_job be "$g" "$MODE" "${EXTRA[@]}"
    want=$(group_be_count "$g")
    wait_for "all BEs alive" backends_all_alive
    wait_for "group $g has $want alive BEs" group_has "$g" "$want"
    # Replicas in $g missed writes while down: let the scheduler repair them BEFORE the
    # next group goes down, otherwise some tablets would have only one current replica.
    fe_cfg_set disable_tablet_scheduler false
    wait_for "zero unhealthy tablets after group $g" tablets_healthy
    fe_cfg_set disable_tablet_scheduler true
  done
fi

# ---------------------------------------------------------------- FE: followers first, master last
if [[ "$COMPONENT" == all || "$COMPONENT" == fe ]]; then
  m=$(master_endpoint); mhost=${m%:*}
  mgroup=$(fe_group_of_host "$mhost")
  [[ -n "$mgroup" ]] || die "cannot map FE master $mhost to a server group"
  order=()
  for g in "${GROUPS_ARR[@]}"; do [[ "$g" != "$mgroup" ]] && order+=("$g"); done
  order+=("$mgroup")
  log "FE order: ${order[*]} (master currently in $mgroup)"
  for g in "${order[@]}"; do
    deploy_job fe "$g" "$MODE" "${EXTRA[@]}"
    wait_for "all FEs alive, joined, one master" frontends_ok
  done
fi

# ---------------------------------------------------------------- done
trap - ERR
# ADMIN SET is in-memory on the master: restore() goes to whichever FE is master NOW.
restore
wait_for "cluster healthy" cluster_healthy
log "rollout finished: mode=$MODE component=$COMPONENT"
