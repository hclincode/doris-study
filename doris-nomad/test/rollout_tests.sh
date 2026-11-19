#!/usr/bin/env bash
# Drives the REAL scripts/rollout.sh against the simulator in test/fakes/fakesim.py.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fails=0

setup() {
  export SIM; SIM=$(mktemp -d)
  mkdir -p "$SIM/bin"
  for b in nomad-pack curl mysql; do ln -s "$ROOT/test/fakes/fakesim.py" "$SIM/bin/$b"; done
  export PATH="$SIM/bin:$PATH" POLL=0.05 GATE_TIMEOUT=20 SIM_MASTER_GROUP=${1:-dc2}
  export ROLLOUT_STATE_FILE=$SIM/rollout-state NOMAD_ADDR=http://nomad:4646
  # initial deployment of all 6 jobs (what bootstrap.sh does)
  ( set -e; source "$ROOT/scripts/lib.sh"
    for g in dc1 dc2 dc3; do pack_run fe "$g" server >/dev/null; done
    for g in dc1 dc2 dc3; do pack_run be "$g" server >/dev/null; done )
  : > "$SIM/events.log"
}
run() {   # name, check args..., -- rollout args...
  local name=$1; shift
  local ck=(); while [[ $1 != -- ]]; do ck+=("$1"); shift; done; shift
  if "$ROOT/scripts/rollout.sh" "$@" >"$SIM/rollout.out" 2>&1 && python3 "$ROOT/test/check_events.py" "${ck[@]}" >"$SIM/check.out" 2>&1; then
    echo "    ok   $name: $(head -1 "$SIM/check.out")"
  else
    echo "    FAIL $name"; tail -15 "$SIM/rollout.out" | sed 's/^/         /'; sed 's/^/         /' "$SIM/check.out"; fails=$((fails+1))
  fi
}

setup dc2
run "server mode, new image: 1 server down at a time, master FE last" server dc2 -- \
    --mode server --var be_image=apache/doris:be-2.1.10 --var fe_image=apache/doris:fe-2.1.10
: > "$SIM/events.log"
run "re-run with no change: nothing restarts" server dc2 --expect-no-roll -- \
    --mode server --var be_image=apache/doris:be-2.1.10 --var fe_image=apache/doris:fe-2.1.10

setup dc1
run "group mode: one whole group at a time, never two, master (dc1) last" group dc1 -- \
    --mode group --var be_image=apache/doris:be-2.1.10 --var fe_image=apache/doris:fe-2.1.10
: > "$SIM/events.log"
run "switch group->server without a version change: no restart" server dc1 --expect-no-roll -- \
    --mode server --var be_image=apache/doris:be-2.1.10 --var fe_image=apache/doris:fe-2.1.10

# unhealthy cluster => refuse to start
setup dc2
python3 - <<'EOF'
import json, os
p = os.path.join(os.environ["SIM"], "state.json"); s = json.load(open(p))
s["repair_pending"] = ["dc3"]; s["cfg"]["disable_tablet_scheduler"] = "true"; json.dump(s, open(p, "w"))
EOF
if "$ROOT/scripts/rollout.sh" --mode server --var be_image=x:1 >"$SIM/rollout.out" 2>&1; then
  echo "    FAIL unhealthy cluster must block the rollout"; fails=$((fails+1))
elif grep -q '^DOWN' "$SIM/events.log"; then
  echo "    FAIL something went down although the cluster was unhealthy"; fails=$((fails+1))
elif ! grep -q 'cluster is not healthy' "$SIM/rollout.out"; then
  echo "    FAIL refused for the wrong reason:"; tail -3 "$SIM/rollout.out"; fails=$((fails+1))
else
  echo "    ok   unhealthy tablets before start: rollout refuses, nothing stopped"
fi

# mutation test: WITHOUT the repair gate between groups the simulator must catch it
setup dc2
sed '/fe_cfg_set disable_tablet_scheduler false/d; /zero unhealthy tablets after group/d' \
  "$ROOT/scripts/rollout.sh" > "$ROOT/scripts/.rollout-mutant.sh"
GATE_TIMEOUT=3 bash "$ROOT/scripts/.rollout-mutant.sh" --mode group --var be_image=x:2 >"$SIM/rollout.out" 2>&1
rm -f "$ROOT/scripts/.rollout-mutant.sh"
if grep -q VIOLATION "$SIM/events.log"; then
  echo "    ok   mutation: removing the inter-group repair gate is detected ($(grep -c VIOLATION "$SIM/events.log") violations)"
else
  echo "    FAIL mutation without repair gate went unnoticed"; fails=$((fails+1))
fi

exit $fails
