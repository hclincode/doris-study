#!/bin/bash
# Doris FE entrypoint (rendered into the job by nomad-pack via fileContents).
# NOTE: no dollar-brace, percent-brace or double-curly sequences in this file.
set -eu

DORIS_HOME=$(printenv DORIS_FE_HOME || echo /opt/apache-doris/fe)
META="$DORIS_FE_META_DIR"
TASK_DIR=$(printenv NOMAD_TASK_DIR || echo /local)
ALLOC_DIR=$(printenv NOMAD_ALLOC_DIR || echo /alloc)
LOCK_WAIT=$(printenv DORIS_LOCK_WAIT || echo 900)

log() { echo "[fe-start] $*"; }

mkdir -p "$META" "$DORIS_HOME/conf"

if [ ! -f "$DORIS_HOME/conf/fe.conf.image" ]; then
  if [ -f "$DORIS_HOME/conf/fe.conf" ]; then
    cp "$DORIS_HOME/conf/fe.conf" "$DORIS_HOME/conf/fe.conf.image"
  else
    : > "$DORIS_HOME/conf/fe.conf.image"
  fi
fi
cat "$DORIS_HOME/conf/fe.conf.image" "$TASK_DIR/fe.conf.nomad" > "$DORIS_HOME/conf/fe.conf"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$META/.nomad-owner.lock"
  log "waiting for exclusive lock on $META (max $LOCK_WAIT s)"
  if ! flock -w "$LOCK_WAIT" 9; then
    log "metadata dir still locked by another process after $LOCK_WAIT s, refusing to start"
    exit 1
  fi
else
  log "WARNING: flock not found in image, single-writer guard disabled"
fi

# Decided by the fe-init prestart task: empty (normal start) or "--helper host:port".
ARGS=""
if [ -f "$ALLOC_DIR/fe-start-args" ]; then
  ARGS=$(cat "$ALLOC_DIR/fe-start-args")
fi
log "starting FE with args: '$ARGS'"

# shellcheck disable=SC2086
exec "$DORIS_HOME/bin/start_fe.sh" --console $ARGS
