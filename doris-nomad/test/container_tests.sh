#!/usr/bin/env bash
# Runs the real in-container scripts against a fake Doris (mysql) and fake start_*.sh.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S=$ROOT/packs/doris/scripts
fails=0
t() { if eval "$2"; then echo "    ok   $1"; else echo "    FAIL $1"; fails=$((fails+1)); fi; }

new_env() {
  W=$(mktemp -d); export DSIM=$W/doris
  mkdir -p "$DSIM" "$W/bin" "$W/local" "$W/alloc" "$W/meta"
  ln -s "$ROOT/test/fakes/container_mysql.py" "$W/bin/mysql"
  export PATH="$W/bin:$PATH" NOMAD_TASK_DIR=$W/local NOMAD_ALLOC_DIR=$W/alloc
  export DORIS_FE_META_DIR=$W/meta FE_JOIN_POLL=0.2 FE_JOIN_TIMEOUT=2 BE_REGISTER_POLL=0.2 BE_REGISTER_TIMEOUT=2
  export SELF_IP=10.0.2.10 EDIT_LOG_PORT=9010 HEARTBEAT_PORT=9050 SERVER_GROUP=dc2 FE_BOOTSTRAP_GROUP=none
  : > "$DSIM/sql.log"
}
master_in() { printf 'fe1\t10.0.1.10\t9010\ttrue\ttrue\n' > "$DSIM/frontends.tsv"; }

echo "  fe-init.sh"
new_env; export SERVER_GROUP=dc1 SELF_IP=10.0.1.10 FE_BOOTSTRAP_GROUP=dc1
sh "$S/fe-init.sh" >/dev/null; rc=$?
t "first FE of a new cluster: starts without --helper" "[ $rc = 0 ] && [ ! -s $W/alloc/fe-start-args ] && [ -e $W/alloc/fe-start-args ]"
t "  ... and runs no ADD FOLLOWER" "! grep -q 'ADD FOLLOWER' $DSIM/sql.log"

new_env; echo "10.0.1.10:9030" > "$W/local/fe_endpoints"; touch "$DSIM/reachable"; master_in
sh "$S/fe-init.sh" >/dev/null; rc=$?
t "empty volume, cluster exists: ADD FOLLOWER self" "[ $rc = 0 ] && grep -q 'ADD FOLLOWER \"10.0.2.10:9010\"' $DSIM/sql.log"
t "  ... and starts with --helper <master edit_log>" "grep -qx -- '--helper 10.0.1.10:9010' $W/alloc/fe-start-args"

new_env; echo "10.0.1.10:9030" > "$W/local/fe_endpoints"; touch "$DSIM/reachable"; master_in
mkdir -p "$W/meta/image"; echo "clusterId=1" > "$W/meta/image/VERSION"
sh "$S/fe-init.sh" >/dev/null; rc=$?
t "metadata on volume (rolling upgrade): plain start" "[ $rc = 0 ] && [ ! -s $W/alloc/fe-start-args ]"
t "  ... and does not touch the cluster" "[ ! -s $DSIM/sql.log ]"

new_env; export FE_BOOTSTRAP_GROUP=dc1   # we are dc2, nothing reachable
sh "$S/fe-init.sh" >/dev/null 2>&1; rc=$?
t "empty volume, no FE, not bootstrap group: refuses (no 2nd cluster)" "[ $rc != 0 ] && [ ! -e $W/alloc/fe-start-args ]"

new_env; export SERVER_GROUP=dc1 SELF_IP=10.0.1.11 FE_BOOTSTRAP_GROUP=dc1
echo "10.0.3.10:9030" > "$W/local/fe_endpoints"; touch "$DSIM/reachable"
printf 'fe3\t10.0.3.10\t9010\ttrue\ttrue\n' > "$DSIM/frontends.tsv"
sh "$S/fe-init.sh" >/dev/null; rc=$?
t "bootstrap group rebuilt while cluster alive: joins, never forks" "[ $rc = 0 ] && grep -qx -- '--helper 10.0.3.10:9010' $W/alloc/fe-start-args"

new_env; echo "10.0.1.10:9030" > "$W/local/fe_endpoints"; touch "$DSIM/reachable"; master_in
printf 'fe2\t10.0.2.10\t9010\tfalse\tfalse\n' >> "$DSIM/frontends.tsv"
sh "$S/fe-init.sh" >/dev/null; rc=$?
t "re-run after ADD but before first start: no duplicate ADD" "[ $rc = 0 ] && ! grep -q 'ADD FOLLOWER' $DSIM/sql.log && grep -q helper $W/alloc/fe-start-args"

new_env; mkdir -p "$W/meta/bdb"; touch "$W/meta/bdb/00000000.jdb"
sh "$S/fe-init.sh" >/dev/null 2>&1; rc=$?
t "half-initialised metadata: stops for an operator" "[ $rc != 0 ]"

echo "  be-register.sh"
new_env; export SELF_IP=10.0.2.21 SERVER_GROUP=dc2
echo "10.0.1.10:9030" > "$W/local/fe_endpoints"; touch "$DSIM/reachable"
sh "$S/be-register.sh" >/dev/null; rc=$?
t "first deploy: ADD BACKEND with tag.location=dc2" "[ $rc = 0 ] && grep -q 'ADD BACKEND \"10.0.2.21:9050\" PROPERTIES (\"tag.location\" = \"dc2\")' $DSIM/sql.log"
: > "$DSIM/sql.log"; sh "$S/be-register.sh" >/dev/null; rc=$?
t "restart / upgrade: already registered, no ALTER" "[ $rc = 0 ] && ! grep -q ALTER $DSIM/sql.log"
printf '9\t10.0.2.21\t9050\ttrue\t{"location" : "default"}\n' > "$DSIM/backends.tsv"; : > "$DSIM/sql.log"
sh "$S/be-register.sh" >/dev/null; rc=$?
t "wrong tag: MODIFY BACKEND to dc2" "[ $rc = 0 ] && grep -q 'MODIFY BACKEND \"10.0.2.21:9050\" SET (\"tag.location\" = \"dc2\")' $DSIM/sql.log"
new_env; export SELF_IP=10.0.2.21 SERVER_GROUP=dc2 BE_REGISTER_TIMEOUT=5
echo "10.0.1.10:9030" > "$W/local/fe_endpoints"
( sleep 1; touch "$DSIM/reachable" ) &
sh "$S/be-register.sh" >/dev/null; rc=$?
t "FE not up yet: retries, then registers" "[ $rc = 0 ] && grep -q 'ADD BACKEND' $DSIM/sql.log"

echo "  be-start.sh / fe-start.sh (local volume single-writer guard)"
mkfake() {   # fake DORIS_HOME with start script recording its start time and args
  H=$W/home; mkdir -p "$H/bin" "$H/conf"
  printf '#!/bin/sh\necho "$(date +%%s.%%N) $*" >> %s/started\n' "$W" > "$H/bin/$1"; chmod +x "$H/bin/$1"
}
new_env; mkfake start_be.sh; export DORIS_BE_HOME=$H DORIS_BE_STORAGE=$W/storage
echo "x = 1" > "$H/conf/be.conf"; printf 'x = 2\nstorage_root_path = %s\n' "$W/storage" > "$W/local/be.conf.nomad"
out=$(bash "$S/be-start.sh"); rc=$?
t "first start on empty volume detected" "[ $rc = 0 ] && grep -q 'empty volume' <<<\"\$out\""
t "be.conf = image defaults + Nomad overrides (ours last)" "[ \"\$(grep '^x' $H/conf/be.conf | tail -1)\" = 'x = 2' ]"
t "start_be.sh --console was exec'd" "grep -q -- '--console' $W/started"
mkdir -p "$W/storage/data"; out=$(bash "$S/be-start.sh")
t "second start sees existing data (upgrade path)" "grep -q 'existing data' <<<\"\$out\""
rm -f "$W/started"
flock "$W/storage/.nomad-owner.lock" sleep 2 & holder=$!; sleep 0.3
t0=$(date +%s.%N); bash "$S/be-start.sh" >/dev/null; wait $holder
t "new BE waits until the old one released the volume" "awk -v t0=$t0 '{exit !(\$1 - t0 >= 1.5)}' $W/started"
rm -f "$W/started"
flock "$W/storage/.nomad-owner.lock" sleep 3 & holder=$!; sleep 0.3
DORIS_LOCK_WAIT=1 bash "$S/be-start.sh" >/dev/null 2>&1; rc=$?; wait $holder
t "never two BEs on one volume: gives up instead of starting" "[ $rc != 0 ] && [ ! -e $W/started ]"

new_env; mkfake start_fe.sh; export DORIS_FE_HOME=$H
echo "meta_dir = x" > "$W/local/fe.conf.nomad"; echo "--helper 10.0.1.10:9010" > "$W/alloc/fe-start-args"
bash "$S/fe-start.sh" >/dev/null
t "fe-start passes the helper decided by fe-init" "grep -q -- '--console --helper 10.0.1.10:9010' $W/started"

exit $fails
