#!/usr/bin/env bash
# Offline test suite. Needs: go, python3 (+ python-hcl2), jq, shellcheck, flock.
#   test/run_tests.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
nok()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() { local d=$1; shift; if "$@" >/tmp/t.out 2>&1; then ok "$d"; else nok "$d"; sed 's/^/        /' /tmp/t.out | tail -20; fi; }

export PACKRENDER=/tmp/packrender
(cd test && go build -o "$PACKRENDER" ./render) || { echo "cannot build renderer"; exit 1; }

render() {   # out_dir args...
  local out=$1; shift
  rm -rf "$out"
  python3 test/packvars.py packs/doris -f vars/common.hcl "$@" >/tmp/vars.json && "$PACKRENDER" packs/doris /tmp/vars.json "$out"
}

echo "== 1. render matrix: one job per component per group, placement, max_parallel, sticky volumes"
for c in be fe; do for g in dc1 dc2 dc3; do for m in server group; do
  out=/tmp/r/$c-$g-$m
  check "render $c $g $m" render "$out" -f "vars/$g.hcl" --var component=$c --var rollout_mode=$m
  check "assert $c $g $m" python3 test/assert_job.py "$out" "$c" "$g" "$m" vars/$g.hcl
done; done; done

echo "== 2. unsafe inputs are rejected at render time"
check "rollout_mode=foo fails"    bash -c '! render /tmp/r/bad1 -f vars/dc1.hcl --var rollout_mode=foo'
check "missing server_group fails" bash -c '! render /tmp/r/bad2 --var component=be'
check "component=xx fails"        bash -c '! render /tmp/r/bad3 -f vars/dc1.hcl --var component=xx'

echo "== 3. switching server<->group changes ONLY update.max_parallel (non-destructive)"
check "be diff server vs group" bash -c "diff /tmp/r/be-dc1-server/doris_be.nomad /tmp/r/be-dc1-group/doris_be.nomad | grep '^[<>]' | grep -v max_parallel | (! grep .)"
check "fe identical server vs group" diff /tmp/r/fe-dc1-server/doris_fe.nomad /tmp/r/fe-dc1-group/doris_fe.nomad

echo "== 4. in-container scripts: first deploy vs restart on the local volume"
bash test/container_tests.sh && ok "container script scenarios" || nok "container script scenarios"

echo "== 5. rollout orchestration (simulated Nomad + Doris)"
bash test/rollout_tests.sh && ok "rollout scenarios" || nok "rollout scenarios"

echo "== 6. shellcheck"
check "shellcheck ops scripts" shellcheck -x -P scripts scripts/*.sh
check "shellcheck container scripts" shellcheck packs/doris/scripts/*.sh

echo
echo "passed=$PASS failed=$FAIL"
((FAIL == 0))
