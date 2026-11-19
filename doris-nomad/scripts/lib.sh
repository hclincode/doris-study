#!/usr/bin/env bash
# Shared helpers for bootstrap.sh / rollout.sh / check-cluster.sh / create-volumes.sh.
# Needs: curl, jq, mysql client, nomad, nomad-pack.
# shellcheck disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${NOMAD_ADDR:=http://127.0.0.1:4646}"
: "${NOMAD_TOKEN:=}"
: "${DORIS_GROUPS:=dc1 dc2 dc3}"          # order = default rollout order
: "${PACK_DIR:=$ROOT/packs/doris}"
: "${VARS_DIR:=$ROOT/vars}"
: "${DORIS_USER:=root}"
: "${MYSQL_PWD:=}"                         # Doris root password (read by the mysql client)
: "${DORIS_FE_ENDPOINTS:=}"                # "ip:9030 ip:9030 ..."; empty = discover via Nomad services
: "${FE_QUERY_SERVICE:=doris-fe-query}"
: "${GATE_TIMEOUT:=3600}"                  # max wait for one gate (s)
: "${POLL:=10}"
export MYSQL_PWD

read -r -a GROUPS_ARR <<<"$DORIS_GROUPS"

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------ Nomad API
nomad_get() {
  local auth=()
  [[ -n "$NOMAD_TOKEN" ]] && auth=(-H "X-Nomad-Token: $NOMAD_TOKEN")
  curl -fsS "${auth[@]}" "$NOMAD_ADDR/v1/$1"
}

job_version() {   # prints job version, or nothing if the job does not exist
  nomad_get "job/$1" 2>/dev/null | jq -r '.Version // empty' || true
}

job_name() { echo "doris-$1-$2"; }   # component group

# Wait until the deployment for job version $2 is successful.
wait_deployment() {
  local job=$1 ver=$2 t0 dep status desc
  t0=$(date +%s)
  log "waiting for deployment of $job v$ver"
  while :; do
    dep=$(nomad_get "job/$job/deployments" |
      jq -c --argjson v "$ver" '[.[] | select(.JobVersion == $v)] | sort_by(.CreateIndex) | last // empty')
    if [[ -n "$dep" ]]; then
      status=$(jq -r '.Status' <<<"$dep")
      desc=$(jq -r '.StatusDescription' <<<"$dep")
      case "$status" in
        successful) log "$job v$ver: deployment successful"; return 0 ;;
        failed|cancelled) die "$job v$ver: deployment $status ($desc). auto_revert rolls back to the last stable version; fix and re-run." ;;
      esac
    elif (( $(date +%s) - t0 > 120 )); then
      # Some updates (e.g. only the update block changed) create no deployment.
      if nomad_get "job/$job/allocations" | jq -e --argjson v "$ver" '
           [.[] | select(.ClientStatus == "running")] as $r
           | ($r | length) > 0 and all($r[]; .JobVersion == $v)' >/dev/null; then
        log "$job v$ver: no deployment created, all running allocations are on v$ver"
        return 0
      fi
    fi
    (( $(date +%s) - t0 > GATE_TIMEOUT )) && die "$job v$ver: deployment not finished after $GATE_TIMEOUT s"
    sleep "$POLL"
  done
}

no_active_deployments() {
  local g c job
  for c in be fe; do
    for g in "${GROUPS_ARR[@]}"; do
      job=$(job_name "$c" "$g")
      if nomad_get "job/$job/deployments" 2>/dev/null |
          jq -e '[.[] | select(.Status == "running" or .Status == "paused" or .Status == "pending")] | length > 0' >/dev/null; then
        log "$job has an active deployment"; return 1
      fi
    done
  done
}

# nomad-pack run for ONE component in ONE group. Extra args are passed through.
pack_run() {
  local c=$1 g=$2 mode=$3; shift 3
  nomad-pack run "$PACK_DIR" --name "$(job_name "$c" "$g")" \
    -f "$VARS_DIR/common.hcl" -f "$VARS_DIR/$g.hcl" \
    --var "component=$c" --var "server_group=$g" --var "rollout_mode=$mode" "$@"
}

pack_plan() {
  local c=$1 g=$2 mode=$3; shift 3
  nomad-pack plan "$PACK_DIR" --name "$(job_name "$c" "$g")" \
    -f "$VARS_DIR/common.hcl" -f "$VARS_DIR/$g.hcl" \
    --var "component=$c" --var "server_group=$g" --var "rollout_mode=$mode" "$@" || true
}

# Deploy one job and block until its deployment is done. No-op if the job did not change.
deploy_job() {
  local c=$1 g=$2 mode=$3; shift 3
  local job before after
  job=$(job_name "$c" "$g")
  before=$(job_version "$job")
  log ">>> $job (mode=$mode)"
  pack_run "$c" "$g" "$mode" "$@"
  after=$(job_version "$job")
  [[ -n "$after" ]] || die "$job was not registered"
  if [[ "$before" == "$after" ]]; then
    log "$job unchanged (v$after), nothing rolled"
    return 0
  fi
  wait_deployment "$job" "$after"
}

# ------------------------------------------------------------------ Doris SQL
fe_endpoints() {
  if [[ -n "$DORIS_FE_ENDPOINTS" ]]; then
    tr ' ' '\n' <<<"$DORIS_FE_ENDPOINTS"
  else
    nomad_get "service/$FE_QUERY_SERVICE" 2>/dev/null | jq -r '.[] | "\(.Address):\(.Port)"' || true
  fi
}

sql_on() {   # endpoint sql
  mysql -h "${1%:*}" -P "${1##*:}" -u"$DORIS_USER" --connect-timeout=5 -B -e "$2"
}

sql_any() {  # first FE that answers
  local ep
  for ep in $(fe_endpoints); do
    if sql_on "$ep" "$1" 2>/dev/null; then return 0; fi
  done
  return 1
}

# Keep only the named columns (by header name) from mysql -B output.
cols() {
  awk -F'\t' -v want="$1" '
    NR==1 { for (i=1;i<=NF;i++) idx[$i]=i; n=split(want,w,","); next }
    { line=""; for (j=1;j<=n;j++) line=line (j>1?"\t":"") $(idx[w[j]]); print line }'
}

master_endpoint() {   # host:query_port of the current FE master
  sql_any "SHOW FRONTENDS" | cols Host,QueryPort,IsMaster | awk -F'\t' '$3=="true" {print $1":"$2; exit}'
}

sql_master() {
  local m; m=$(master_endpoint)
  [[ -n "$m" ]] || { log "no FE master found"; return 1; }
  sql_on "$m" "$1"
}

fe_cfg_get() { sql_master "ADMIN SHOW FRONTEND CONFIG LIKE '$1'" | cols Value | head -1; }
fe_cfg_set() { log "FE master config $1=$2"; sql_master "ADMIN SET FRONTEND CONFIG (\"$1\" = \"$2\")" >/dev/null; }

# ------------------------------------------------------------------ gates
backends_all_alive() {
  local out; out=$(sql_any "SHOW BACKENDS" | cols Alive) || return 1
  [[ -n "$out" ]] && ! grep -qv '^true$' <<<"$out"
}

backends_in_group() {   # group -> count of alive BEs tagged with it
  sql_any "SHOW BACKENDS" | cols Alive,Tag |
    awk -F'\t' -v g="$1" '$1=="true" && $2 ~ ("\"location\" *: *\"" g "\"") {n++} END {print n+0}'
}

frontends_ok() {   # all alive, all joined, exactly one master
  local out; out=$(sql_any "SHOW FRONTENDS" | cols Alive,Join,IsMaster) || return 1
  [[ -n "$out" ]] || return 1
  awk -F'\t' '$1!="true" || $2!="true" {bad=1} $3=="true" {m++} END {exit (bad || m!=1)}' <<<"$out"
}

unhealthy_tablets() {
  sql_master "SHOW PROC '/cluster_health/tablet_health'" | cols DbName,TabletNum,HealthyNum |
    awk -F'\t' '$1!="Total" {s += $2 - $3} END {print s+0}'
}

tablets_healthy() { [[ "$(unhealthy_tablets)" == "0" ]]; }

wait_for() {   # description, command...
  local what=$1 t0; shift
  t0=$(date +%s)
  until "$@"; do
    (( $(date +%s) - t0 > GATE_TIMEOUT )) && die "timed out waiting for: $what"
    log "waiting for: $what"
    sleep "$POLL"
  done
  log "ok: $what"
}

fe_group_of_host() {   # Doris FE host -> server group (via Nomad service tags)
  nomad_get "service/$FE_QUERY_SERVICE" | jq -r --arg h "$1" '.[] | select(.Address == $h) | .Tags[0]' | head -1
}
