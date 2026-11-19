#!/usr/bin/env bash
# FIRST deployment of the Doris cluster. Run once. Re-running is safe (every step is idempotent),
# but day-2 changes go through scripts/rollout.sh.
#
#   DORIS_ROOT_PASSWORD='...' scripts/bootstrap.sh
#
# Order:
#   1. local-disk volumes on every Doris node
#   2. Nomad Variable nomad/jobs/doris (root_password, fe_bootstrap_group) + ACL policy
#   3. FE in the first group (creates the cluster), then FE in the other groups (join as followers)
#   4. turn the bootstrap flag off (no later empty FE can ever create a second cluster)
#   5. root password
#   6. BE groups (each BE registers itself with tag.location = its group)
#   7. check: 3 FEs, BEs tagged per group
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

: "${DORIS_ROOT_PASSWORD:=}"
: "${ACL_ENABLED:=auto}"
VAR_PATH=nomad/jobs/doris
BOOT=${GROUPS_ARR[0]}

log "1/7 volumes"
"$ROOT/scripts/create-volumes.sh"

log "2/7 Nomad variable $VAR_PATH (bootstrap group = $BOOT)"
current_pw=""
if nomad var get "$VAR_PATH" >/dev/null 2>&1; then
  current_pw=$(nomad var get -item=root_password "$VAR_PATH" 2>/dev/null || true)
fi
nomad var put -force "$VAR_PATH" root_password="$current_pw" fe_bootstrap_group="$BOOT" >/dev/null
export MYSQL_PWD=$current_pw

if [[ "$ACL_ENABLED" == auto ]]; then
  ACL_ENABLED=$(nomad acl token self >/dev/null 2>&1 && echo 1 || echo 0)
fi
if [[ "$ACL_ENABLED" == 1 ]]; then
  for c in be fe; do for g in "${GROUPS_ARR[@]}"; do
    nomad acl policy apply -namespace default -job "$(job_name "$c" "$g")" \
      "doris-vars-$c-$g" "$ROOT/acl/doris-vars.policy.hcl"
  done; done
fi

log "3/7 FE: $BOOT first (creates the cluster), then the others join"
deploy_job fe "$BOOT" server
for g in "${GROUPS_ARR[@]:1}"; do
  deploy_job fe "$g" server
done
wait_for "3 FEs alive, joined, one master" frontends_ok
n=$(sql_any "SHOW FRONTENDS" | cols Host | wc -l)
[[ "$n" -eq "${#GROUPS_ARR[@]}" ]] || die "expected ${#GROUPS_ARR[@]} FEs, found $n"

log "4/7 bootstrap flag off"
nomad var put -force "$VAR_PATH" root_password="$current_pw" fe_bootstrap_group=none >/dev/null

log "5/7 root password"
if [[ -n "$DORIS_ROOT_PASSWORD" && "$DORIS_ROOT_PASSWORD" != "$current_pw" ]]; then
  sql_master "SET PASSWORD FOR 'root' = PASSWORD('$DORIS_ROOT_PASSWORD')" >/dev/null
  nomad var put -force "$VAR_PATH" root_password="$DORIS_ROOT_PASSWORD" fe_bootstrap_group=none >/dev/null
  export MYSQL_PWD=$DORIS_ROOT_PASSWORD
fi

log "6/7 BE groups"
for g in "${GROUPS_ARR[@]}"; do
  deploy_job be "$g" server
done
wait_for "all BEs alive" backends_all_alive

log "7/7 check"
"$ROOT/scripts/check-cluster.sh"
log "bootstrap done. Now create tables with replication_allocation, see sql/replica-policy.sql"
