#!/usr/bin/env bash
# Checks requirement 1: three replicas in three different server groups.
#   scripts/check-cluster.sh                 # FEs, BE tags per group, tablet health
#   scripts/check-cluster.sh --audit-tables  # + every OLAP partition has 1 replica per group
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

AUDIT=0; [[ "${1:-}" == --audit-tables ]] && AUDIT=1
fail=0
bad() { log "FAIL: $*"; fail=1; }

if frontends_ok; then log "ok: FEs alive, joined, one master"; else bad "FEs not healthy"; fi

for g in "${GROUPS_ARR[@]}"; do
  n=$(backends_in_group "$g")
  want=$(awk -F= '/^[[:space:]]*be_count/ {gsub(/[[:space:]]/,"",$2); print $2}' "$VARS_DIR/$g.hcl")
  if [[ "$n" -ge "$want" ]]; then log "ok: group $g has $n alive BEs tagged location=$g"; else bad "group $g: $n alive tagged BEs, expected $want"; fi
done

untagged=$(sql_any "SHOW BACKENDS" | cols Host,Tag | awk -F'\t' -v gs="${GROUPS_ARR[*]}" '
  { ok=0; n=split(gs,a," "); for (i=1;i<=n;i++) if ($2 ~ ("\"location\" *: *\"" a[i] "\"")) ok=1; if (!ok) print $1 }')
if [[ -z "$untagged" ]]; then log "ok: every BE carries a server-group tag"; else bad "BEs without a server-group tag: $untagged"; fi

u=$(unhealthy_tablets)
if [[ "$u" == 0 ]]; then log "ok: 0 unhealthy tablets"; else bad "$u unhealthy tablets"; fi

if ((AUDIT)); then
  expected=$(printf 'tag.location.%s: 1\n' "${GROUPS_ARR[@]}" | sort | paste -sd, -)
  for db in $(sql_any "SHOW DATABASES" | tail -n +2 | grep -Ev '^(information_schema|mysql|__internal_schema)$'); do
    for t in $(sql_any "SHOW FULL TABLES FROM \`$db\`" | awk -F'\t' 'NR>1 && $2=="BASE TABLE" {print $1}'); do
      sql_any "SHOW PARTITIONS FROM \`$db\`.\`$t\`" 2>/dev/null | cols PartitionName,ReplicaAllocation |
      while IFS=$'\t' read -r p ra; do
        got=$(tr ',' '\n' <<<"$ra" | sed 's/^ *//' | sort | paste -sd, -)
        [[ "$got" == "$expected" ]] || { echo "$db.$t partition $p: $ra"; }
      done
    done
  done > /tmp/doris-bad-partitions.txt
  if [[ -s /tmp/doris-bad-partitions.txt ]]; then
    bad "partitions NOT placed one replica per group (see sql/replica-policy.sql):"
    cat /tmp/doris-bad-partitions.txt >&2
  else
    log "ok: every partition has one replica in each of: ${GROUPS_ARR[*]}"
  fi
fi

exit $fail
