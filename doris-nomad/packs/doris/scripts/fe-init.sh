#!/bin/sh
# FE prestart task: decides HOW this FE starts, from what is on its local volume.
#   1. metadata present                     -> normal start (restart / rolling upgrade)
#   2. empty volume, an FE master reachable -> ALTER SYSTEM ADD FOLLOWER, start with --helper
#   3. empty volume, no FE reachable, and FE_BOOTSTRAP_GROUP == this group
#                                           -> start as the first FE (creates the cluster)
#   otherwise wait (never create a second cluster => no split brain).
# NOTE: no dollar-brace, percent-brace or double-curly sequences in this file.
set -eu

META="$DORIS_FE_META_DIR"
TASK_DIR=$(printenv NOMAD_TASK_DIR || echo /local)
ALLOC_DIR=$(printenv NOMAD_ALLOC_DIR || echo /alloc)
ENDPOINTS_FILE="$TASK_DIR/fe_endpoints"
OUT="$ALLOC_DIR/fe-start-args"
BOOT_GROUP=$(printenv FE_BOOTSTRAP_GROUP || echo none)
TIMEOUT=$(printenv FE_JOIN_TIMEOUT || echo 900)
SLEEP=$(printenv FE_JOIN_POLL || echo 10)
DORIS_USER=$(printenv DORIS_USER || echo root)

log() { echo "[fe-init] $*"; }

# Run SQL on host:port, print only the named columns (tab separated), no header.
q_cols() {
  ep=$1; sql=$2; cols=$3
  h=$(echo "$ep" | cut -d: -f1); p=$(echo "$ep" | cut -d: -f2)
  mysql -h "$h" -P "$p" -u"$DORIS_USER" --connect-timeout=5 -B -e "$sql" 2>/dev/null |
    awk -F'\t' -v want="$cols" '
      NR==1 { for (i=1;i<=NF;i++) idx[$i]=i; n=split(want,w,","); next }
      { line=""; for (j=1;j<=n;j++) line=line (j>1?"\t":"") $(idx[w[j]]); print line }'
}

# ---- 1. existing metadata -> plain restart --------------------------------------
if [ -f "$META/image/VERSION" ]; then
  log "metadata found on volume ($META/image/VERSION): normal start"
  : > "$OUT"
  exit 0
fi
if [ -d "$META/bdb" ] && [ -n "$(ls -A "$META/bdb" 2>/dev/null)" ]; then
  log "ERROR: $META/bdb has data but image/VERSION is missing: half-initialised FE."
  log "Recover manually: DROP FOLLOWER on the master, wipe this volume, restart the allocation."
  exit 1
fi

log "empty metadata volume: first start of this FE (group=$SERVER_GROUP, bootstrap_group=$BOOT_GROUP)"
# SELF_IP, EDIT_LOG_PORT, SERVER_GROUP come from the job env block.
# shellcheck disable=SC2153
SELF_HOST="$SELF_IP"
SELF_EP="$SELF_IP:$EDIT_LOG_PORT"

start=$(date +%s)
while :; do
  for ep in $(cat "$ENDPOINTS_FILE" 2>/dev/null || true); do
    rows=$(q_cols "$ep" "SHOW FRONTENDS" "Host,EditLogPort,IsMaster") || continue
    [ -n "$rows" ] || continue
    master=$(echo "$rows" | awk -F'\t' '$3=="true" {print $1":"$2; exit}')
    [ -n "$master" ] || continue

    if echo "$rows" | awk -F'\t' -v h="$SELF_HOST" -v p="$EDIT_LOG_PORT" '$1==h && $2==p {f=1} END {exit !f}'; then
      log "this FE ($SELF_EP) is already registered in the cluster"
    else
      log "registering follower $SELF_EP via $ep (master $master)"
      h=$(echo "$ep" | cut -d: -f1); p=$(echo "$ep" | cut -d: -f2)
      mysql -h "$h" -P "$p" -u"$DORIS_USER" --connect-timeout=5 \
        -e "ALTER SYSTEM ADD FOLLOWER \"$SELF_EP\"" || { log "ADD FOLLOWER failed, retrying"; continue; }
    fi
    echo "--helper $master" > "$OUT"
    log "will start with --helper $master"
    exit 0
  done

  if [ "$BOOT_GROUP" = "$SERVER_GROUP" ]; then
    log "no FE reachable and this is the bootstrap group: creating a NEW cluster"
    : > "$OUT"
    exit 0
  fi

  now=$(date +%s)
  if [ $((now - start)) -ge "$TIMEOUT" ]; then
    log "ERROR: no FE master reachable after $TIMEOUT s and this group is not the bootstrap group"
    exit 1
  fi
  log "waiting for a reachable FE master..."
  sleep "$SLEEP"
done
