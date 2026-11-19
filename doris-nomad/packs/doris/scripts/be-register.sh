#!/bin/sh
# BE poststart task: make sure this BE is in the cluster with tag.location = server group.
#   first deploy          -> ALTER SYSTEM ADD BACKEND ... PROPERTIES ("tag.location"=group)
#   restart / upgrade     -> already registered with the right tag: no-op
#   registered, wrong tag -> ALTER SYSTEM MODIFY BACKEND ... SET ("tag.location"=group)
# NOTE: no dollar-brace, percent-brace or double-curly sequences in this file.
set -eu

TASK_DIR=$(printenv NOMAD_TASK_DIR || echo /local)
ENDPOINTS_FILE="$TASK_DIR/fe_endpoints"
TIMEOUT=$(printenv BE_REGISTER_TIMEOUT || echo 900)
SLEEP=$(printenv BE_REGISTER_POLL || echo 10)
DORIS_USER=$(printenv DORIS_USER || echo root)
# SELF_IP, HEARTBEAT_PORT, SERVER_GROUP come from the job env block.
# shellcheck disable=SC2153
SELF_EP="$SELF_IP:$HEARTBEAT_PORT"

log() { echo "[be-register] $*"; }

q() {
  ep=$1; sql=$2
  h=$(echo "$ep" | cut -d: -f1); p=$(echo "$ep" | cut -d: -f2)
  mysql -h "$h" -P "$p" -u"$DORIS_USER" --connect-timeout=5 -B -e "$sql"
}

q_cols() {
  q "$1" "$2" 2>/dev/null |
    awk -F'\t' -v want="$3" '
      NR==1 { for (i=1;i<=NF;i++) idx[$i]=i; n=split(want,w,","); next }
      { line=""; for (j=1;j<=n;j++) line=line (j>1?"\t":"") $(idx[w[j]]); print line }'
}

start=$(date +%s)
while :; do
  for ep in $(cat "$ENDPOINTS_FILE" 2>/dev/null || true); do
    rows=$(q_cols "$ep" "SHOW BACKENDS" "Host,HeartbeatPort,Tag") || continue
    mine=$(echo "$rows" | awk -F'\t' -v h="$SELF_IP" -v p="$HEARTBEAT_PORT" '$1==h && $2==p')

    if [ -z "$mine" ]; then
      log "adding backend $SELF_EP with tag.location=$SERVER_GROUP via $ep"
      q "$ep" "ALTER SYSTEM ADD BACKEND \"$SELF_EP\" PROPERTIES (\"tag.location\" = \"$SERVER_GROUP\")" \
        || { log "ADD BACKEND failed, retrying"; continue; }
      exit 0
    fi

    if echo "$mine" | grep -Eq "\"location\" *: *\"$SERVER_GROUP\""; then
      log "backend $SELF_EP already registered with tag.location=$SERVER_GROUP"
      exit 0
    fi

    log "backend $SELF_EP has wrong tag ($mine), setting tag.location=$SERVER_GROUP"
    q "$ep" "ALTER SYSTEM MODIFY BACKEND \"$SELF_EP\" SET (\"tag.location\" = \"$SERVER_GROUP\")" \
      || { log "MODIFY BACKEND failed, retrying"; continue; }
    exit 0
  done

  now=$(date +%s)
  if [ $((now - start)) -ge "$TIMEOUT" ]; then
    log "ERROR: no FE reachable after $TIMEOUT s"
    exit 1
  fi
  log "waiting for a reachable FE..."
  sleep "$SLEEP"
done
