# Apache Doris on Nomad: local disk, 3 server groups, two rollout modes

```
packs/doris/                 nomad-pack: renders ONE job = one component in one server group
  templates/doris_be.nomad.tpl   BE job (count = be_count, sticky local volume, register task)
  templates/doris_fe.nomad.tpl   FE job (1 follower per group, sticky local volume, fe-init task)
  scripts/*.sh                   in-container entrypoints (embedded with fileContents)
vars/common.hcl, vars/dcN.hcl    versions + per-group settings
scripts/create-volumes.sh        local-disk dynamic host volumes, one per node (idempotent)
scripts/bootstrap.sh             first deploy
scripts/rollout.sh               every later change: --mode server | --mode group
scripts/check-cluster.sh         replica-placement check (--audit-tables for every partition)
sql/replica-policy.sql           replication_allocation: one replica per server group
acl/doris-vars.policy.hcl        lets the jobs read nomad/jobs/doris (if ACLs are on)
test/run_tests.sh                offline test suite (see "What is tested")
```

Jobs: `doris-fe-dc1..3` and `doris-be-dc1..3`. Requires Nomad >= 1.10 (dynamic host volumes + `sticky`).

## How each requirement is met

| Requirement | Mechanism |
|---|---|
| 1. Three replicas in three server groups | Nomad: each job is pinned to one group (`datacenters` + `node.meta.server_group`). Doris: every BE registers itself with `tag.location = <group>`, and tables use `replication_allocation = tag.location.dc1:1, dc2:1, dc3:1` (sql/replica-policy.sql). `check-cluster.sh --audit-tables` verifies every partition. |
| 2. Roll by server group (at most one group down) | `rollout.sh --mode group` gives `max_parallel = be_count`, so the whole group is replaced at once. Groups are separate jobs, rolled one after another; the next group starts only after the deployment succeeds **and** Doris reports 0 unhealthy tablets. |
| 3. Roll across groups (at most one server down in the cluster) | `rollout.sh --mode server` gives `max_parallel = 1` in every job, with jobs strictly sequential (BE dc1 → dc2 → dc3 → FE followers → FE master). |
| 4. Local disk, first deploy vs rolling upgrade | Volumes are created up front, one per node; `sticky = true` means every replacement gets the same volume (same node, same data). First start vs restart is decided from the volume contents (table below). |

Switching between `server` and `group` changes only `update.max_parallel`, which does not restart anything (tested). You can choose the mode for each rollout.

### What happens on the local volume

| Situation | FE (`fe-init` prestart) | BE (`register` poststart) |
|---|---|---|
| First deploy, bootstrap group | empty `doris-meta`, no FE reachable, `fe_bootstrap_group` = this group → starts as the first FE | — |
| First deploy, other groups | empty → `ALTER SYSTEM ADD FOLLOWER self` → start `--helper <master>` | `ADD BACKEND ... ("tag.location"=group)` |
| Rolling upgrade / restart | `image/VERSION` present → plain start, no SQL | already registered with the right tag → no-op |
| Rebuilt node (empty volume, cluster alive) | joins as a follower, **never** creates a second cluster (bootstrap flag is `none` after bootstrap) | registers again; Doris re-replicates its tablets |
| Half-initialised metadata | stops and asks for an operator | — |
| Old allocation still in `kill_timeout` | new FE/BE waits on a `flock` on the volume; it never runs two writers on one disk | same |

Repair and balance are disabled during the rollout (`disable_balance`, `disable_colocate_balance`, `disable_tablet_scheduler`), as the Doris upgrade guide requires. The tablet scheduler is turned back on **between groups** only, until the group that just returned has caught up on the writes it missed. Within one group no gate is needed, because a tablet never has two replicas in the same group.

## Prerequisites

Nomad client config on every Doris node:

```hcl
client {
  node_pool = "doris"
  meta {
    server_group = "dc1"     # dc1 | dc2 | dc3
    doris_be     = "true"    # this node runs a BE
    doris_fe     = "true"    # this node runs the group's FE (at least one node per group)
  }
  # put dynamic host volumes on the local NVMe (mkdir plugin), or use an LVM/ZFS plugin
  host_volumes_dir = "/data/nomad/host_volumes"
}
```

Also: Docker driver, Doris host settings (`vm.max_map_count`, swap off, ulimits), `priority_networks` covering the node IPs, and tools on the operator machine: `nomad`, `nomad-pack`, `jq`, `curl`, `mysql`.

## First deploy

```bash
export NOMAD_ADDR=... NOMAD_TOKEN=...
DORIS_ROOT_PASSWORD='***' scripts/bootstrap.sh
# then create tables with replication_allocation (sql/replica-policy.sql)
scripts/check-cluster.sh --audit-tables
```

## Rolling upgrade

```bash
# edit vars/common.hcl (be_image / fe_image), then preview the changes:
scripts/rollout.sh --mode server --plan
scripts/rollout.sh --mode server        # one server down in the whole cluster
scripts/rollout.sh --mode group         # one whole server group down, never two
scripts/rollout.sh --mode server --component be --var be_image=apache/doris:be-X.Y.Z
```

The script refuses to start if any FE or BE is dead, any tablet is unhealthy, or a deployment is still running. If a step fails, it leaves repair and balance disabled on purpose and prints the restore commands. Re-running the script resumes the rollout and restores the original values at the end.

**Only `rollout.sh` should apply changes.** Running `nomad-pack run` by hand on two groups at once breaks requirements 2 and 3. Put this behind a CI lock or ACL.

## Node failure (data on that disk is gone)

Nothing is rescheduled elsewhere (`disconnect.replace = false`, sticky volume), and the allocation stays pending. To move the member to a spare node:

1. **BE:** `ALTER SYSTEM DECOMMISSION BACKEND` (or `DROP BACKEND` if it is gone for good) for the dead host. **FE:** `ALTER SYSTEM DROP FOLLOWER "ip:9010"`.
2. Delete the task group's sticky volume claim through the Nomad Volumes API (host volume claims). Nomad then claims a free volume with the same name on another node in the group.
3. The new allocation starts on an empty volume, and the table above applies: the FE joins, the BE registers and Doris re-replicates.
4. Run `scripts/create-volumes.sh` after adding a node, to recreate the spare.

## What is tested (`test/run_tests.sh`, 33 checks)

- **Render (12 jobs):** an embedded renderer with the same `[[ ]]` template engine. Checks: one job per render, pinning to the group, `max_parallel` per mode, sticky volume, static ports, `distinct_hosts`, `disconnect`, no HCL `${}` or `%{}` and no `{{ }}` inside embedded scripts. Unsafe inputs (bad mode, missing group) fail the render.
- **In-container scripts against a fake Doris:** every row of the local-volume table above, including split-brain prevention and the `flock` single-writer guard (a new BE waits for the old one, and gives up rather than running two).
- **Rollout against a simulated Nomad + Doris:** peak servers down is 1 in server mode and 3 (one group) in group mode, and two groups are never down at once. BE runs before FE, and the master FE goes last. ADMIN SET always goes to the master. Config is restored at the end. Re-running with no changes restarts nothing. An unhealthy cluster blocks the rollout. A mutation test confirms that removing the inter-group repair gate gets caught.
- shellcheck is clean.

**Not tested here; do this once on a staging cluster before production:**

1. Run `nomad-pack render` with your nomad-pack version (`fileContents`, `meta "pack.path"`, `list`, `fail`), then `nomad job validate`.
2. Confirm the Doris image paths (`/opt/apache-doris/{fe,be}`, `start_*.sh --console`), that `flock` exists in the images, and that the `SHOW BACKENDS` / `SHOW FRONTENDS` / `tablet_health` column names match your Doris version.
3. Kill a BE allocation and check that the replacement comes back on the same node and volume. Then run `rollout.sh` in both modes while a load is running.
