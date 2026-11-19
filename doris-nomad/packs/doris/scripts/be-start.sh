#!/bin/bash
# Doris BE entrypoint (rendered into the job by nomad-pack via fileContents).
# NOTE: no dollar-brace, percent-brace or double-curly sequences in this file:
# it is embedded in an HCL heredoc and a consul-template block.
set -eu

DORIS_HOME=$(printenv DORIS_BE_HOME || echo /opt/apache-doris/be)
STORAGE="$DORIS_BE_STORAGE"
TASK_DIR=$(printenv NOMAD_TASK_DIR || echo /local)
LOCK_WAIT=$(printenv DORIS_LOCK_WAIT || echo 900)

log() { echo "[be-start] $*"; }

mkdir -p "$STORAGE" "$DORIS_HOME/conf"

# --- config: image defaults + Nomad-rendered overrides (later keys win) ----------
if [ ! -f "$DORIS_HOME/conf/be.conf.image" ]; then
  if [ -f "$DORIS_HOME/conf/be.conf" ]; then
    cp "$DORIS_HOME/conf/be.conf" "$DORIS_HOME/conf/be.conf.image"
  else
    : > "$DORIS_HOME/conf/be.conf.image"
  fi
fi
cat "$DORIS_HOME/conf/be.conf.image" "$TASK_DIR/be.conf.nomad" > "$DORIS_HOME/conf/be.conf"

# --- single-writer guard on the local volume -------------------------------------
# During a rolling upgrade the replacement allocation lands on the SAME node/volume.
# If the previous BE is still inside its kill_timeout, wait for it to release the
# lock instead of starting a second BE on the same storage.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$STORAGE/.nomad-owner.lock"
  log "waiting for exclusive lock on $STORAGE (max $LOCK_WAIT s)"
  if ! flock -w "$LOCK_WAIT" 9; then
    log "storage still locked by another process after $LOCK_WAIT s, refusing to start"
    exit 1
  fi
else
  log "WARNING: flock not found in image, single-writer guard disabled"
fi

if [ -z "$(find "$STORAGE" -mindepth 1 -maxdepth 1 ! -name '.nomad-owner*' | head -1)" ]; then
  log "empty volume: first start of this BE (it will be registered by the register task)"
else
  log "existing data on volume: restart / rolling upgrade"
fi
echo "alloc=$(printenv NOMAD_ALLOC_ID || echo unknown) started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STORAGE/.nomad-owner"

# fd 9 (the lock) is inherited by doris_be and released only when it exits.
exec "$DORIS_HOME/bin/start_be.sh" --console
