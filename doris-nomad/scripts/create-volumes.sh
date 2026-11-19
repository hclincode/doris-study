#!/usr/bin/env bash
# Create the local-disk dynamic host volumes, one per Doris node, BEFORE the first deploy.
# Idempotent: a node that already has the volume is skipped. Volumes are never deleted
# by this script, by nomad-pack destroy, or by scaling down.
#
#   scripts/create-volumes.sh            # BE + FE volumes in all groups
#   PLUGIN_ID=lvm-thin CAPACITY_MIN=500G scripts/create-volumes.sh
#
# Node selection (client config):
#   node_pool = "doris"
#   meta { server_group = "dc1"  doris_be = "true"  doris_fe = "true" }
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

: "${NODE_POOL:=doris}"
: "${PLUGIN_ID:=mkdir}"        # built-in plugin: a directory under the client's host_volumes_dir
: "${CAPACITY_MIN:=}"           # e.g. 500G, used by real provisioning plugins
: "${BE_VOLUME:=doris-be-storage}"
: "${FE_VOLUME:=doris-fe-meta}"
: "${META_KEY:=server_group}"
: "${DRY_RUN:=0}"

existing=$(nomad_get "volumes?type=host" | jq -r '.[] | "\(.Name) \(.NodeID)"')

create() {   # name node_id node_name
  local name=$1 node=$2 nname=$3 spec
  if grep -qx "$name $node" <<<"$existing"; then
    log "skip: $name already exists on $nname"; return
  fi
  spec=$(mktemp)
  {
    echo "name      = \"$name\""
    echo "type      = \"host\""
    echo "plugin_id = \"$PLUGIN_ID\""
    echo "node_id   = \"$node\""
    [[ -n "$CAPACITY_MIN" ]] && echo "capacity_min = \"$CAPACITY_MIN\""
    echo 'capability {'
    echo '  access_mode     = "single-node-writer"'
    echo '  attachment_mode = "file-system"'
    echo '}'
    [[ "$PLUGIN_ID" == mkdir ]] && printf 'parameters {\n  mode = "0750"\n}\n'
  } >"$spec"
  log "create: $name on $nname"
  if ((DRY_RUN)); then cat "$spec"; else nomad volume create "$spec"; fi
  rm -f "$spec"
}

for g in "${GROUPS_ARR[@]}"; do
  nbe=0; nfe=0
  for id in $(nomad_get "nodes?filter=$(jq -rn --arg p "$NODE_POOL" '"NodePool == \"\($p)\"" | @uri')" | jq -r '.[].ID'); do
    node=$(nomad_get "node/$id")
    [[ "$(jq -r --arg k "$META_KEY" '.Meta[$k] // ""' <<<"$node")" == "$g" ]] || continue
    nname=$(jq -r '.Name' <<<"$node")
    if [[ "$(jq -r '.Meta.doris_be // ""' <<<"$node")" == true ]]; then create "$BE_VOLUME" "$id" "$nname"; nbe=$((nbe+1)); fi
    if [[ "$(jq -r '.Meta.doris_fe // ""' <<<"$node")" == true ]]; then create "$FE_VOLUME" "$id" "$nname"; nfe=$((nfe+1)); fi
  done
  want=$(awk -F= '/^[[:space:]]*be_count/ {gsub(/[[:space:]]/,"",$2); print $2}' "$VARS_DIR/$g.hcl")
  log "group $g: $nbe BE volume nodes (be_count=$want), $nfe FE volume nodes"
  (( nbe >= want )) || die "group $g needs at least $want nodes with meta.doris_be=true"
  (( nfe >= 1 )) || die "group $g needs at least 1 node with meta.doris_fe=true"
  (( nbe > want )) || log "note: group $g has no spare BE node; a dead node then needs a new node + volume before its BE can come back"
done
