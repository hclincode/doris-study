# user input
Update my enviroment. I deploy apache doris with 3 replica on 3 different server group in different DC which defined in nomad-pack. I want to let three replicas distirbute in 3 server groups. I can accpet rolling upgrade at most 1 server group down. sometimes, rolling upgrade should be at max parallel as 1 server across all groups.
## response
I'm assuming each server group is one DC with one or more Doris BEs, plus one FE follower per DC (3 FEs in total). Correct me if your FE layout is different.

## 1. Use one Nomad job per server group

Two rules from before decide this:

- `max_parallel` applies within a single task group.
- Separate task groups, even inside the same job, roll out at the same time.

That means a single task group with `count = 3 × k` spread across the DCs can do one server at a time. It cannot do one whole DC at a time: with `max_parallel = k`, Nomad might pick allocations in two different DCs, and two DCs down at once means two replicas of the same tablet are gone. Putting three groups in one job is no better, because all three DCs would roll together.

So render the **same pack 3 times as 3 jobs** (`doris-be-dc1/2/3`, `doris-fe-dc1/2/3`) and let a rollout script decide the order. Your two modes then come from two settings:

| Mode | `max_parallel` inside each job | Script order | Worst case down |
|---|---|---|---|
| `group` | = BE count in that group | dc1 → gate → dc2 → gate → dc3 | 1 whole server group |
| `server` | 1 | same, one job after another | 1 server in the whole cluster |

## 2. Make Doris able to survive one server group going down

Spreading the Nomad allocations across DCs is not enough. Doris also has to place **one replica of every tablet in each group**. Without that, it can put two replicas of a tablet in the same DC.

```sql
-- once per BE (automate in a poststart task or your bootstrap script)
ALTER SYSTEM MODIFY BACKEND "10.1.0.11:9050" SET ("tag.location" = "dc1");

-- every table (or set as a database default, if your Doris version supports it)
"replication_allocation" = "tag.location.dc1: 1, tag.location.dc2: 1, tag.location.dc3: 1"
```

With this, losing one DC leaves 2 of 3 replicas. Loads still reach a majority and queries still find a replica. Check old tables with `SHOW CREATE TABLE` and run `ALTER TABLE ... MODIFY PARTITION` on any that still use plain `replication_num = 3`.

## 3. The pack

```hcl
# variables.hcl
variable "server_group" { type = string }              # dc1 | dc2 | dc3
variable "be_count"     { type = number  default = 1 }
variable "rollout_mode" { type = string  default = "server" }   # server | group
variable "be_image"     { type = string }
```

```hcl
# templates/doris-be.nomad.tpl
job "doris-be-[[ var "server_group" . ]]" {
  datacenters = ["[[ var "server_group" . ]]"]
  node_pool   = "doris"

  group "be" {
    count = [[ var "be_count" . ]]
    constraint { operator = "distinct_hosts"  value = "true" }

    volume "storage" {
      type   = "host"
      source = "doris-be-storage"
      sticky = true
      access_mode = "single-node-writer"
      attachment_mode = "file-system"
    }

    disconnect { lost_after = "30m"  replace = false  reconcile = "keep_original" }
    reschedule { attempts = 0  unlimited = false }

    update {
      max_parallel     = [[ if eq (var "rollout_mode" .) "group" ]][[ var "be_count" . ]][[ else ]]1[[ end ]]
      health_check     = "checks"
      min_healthy_time = "30s"
      healthy_deadline = "10m"
      auto_revert      = true
      canary           = 0
    }

    network {
      mode = "host"        # FE registers BEs by IP:heartbeat_port, so keep them stable
      port "heartbeat" { static = 9050 }
      port "be"        { static = 9060 }
      port "http"      { static = 8040 }
      port "brpc"      { static = 8060 }
    }

    service {
      name = "doris-be"
      tags = ["[[ var "server_group" . ]]"]
      port = "http"
      check { type = "http"  path = "/api/health"  interval = "5s"  timeout = "2s" }
    }

    task "be" {
      driver       = "docker"
      config { image = "[[ var "be_image" . ]]"  network_mode = "host" }
      kill_timeout = "120s"
      volume_mount { volume = "storage"  destination = "/opt/apache-doris/be/storage" }
    }
  }
}
```

Deploy each group under its own name. Never run the pack for all three groups in a single command or merge:

```bash
nomad-pack run ./packs/doris -f groups/dc1.hcl --name doris-dc1 --var rollout_mode=group
```

The FE pack follows the same pattern: one job per DC, `count = 1`, a sticky `doris-meta` volume, static ports 8030, 9010, 9020 and 9030, and an HTTP check on `/api/bootstrap`.

## 4. The rollout script

Doris's own order is: upgrade BE first, then upgrade FE. When upgrading FE, upgrade the Observer FE and Follower FE nodes first, and upgrade the Master FE node last. Before you start, turn off replica repair and balancing using admin set frontend config("disable_colocate_balance" = "true"); admin set frontend config("disable_tablet_scheduler" = "true");, and set `disable_balance` to `true` as well.

```bash
#!/usr/bin/env bash
set -euo pipefail
MODE=${1:-server}; GROUPS=(dc1 dc2 dc3)
sql() { mysql -h "$FE_VIP" -P9030 -uroot -N -e "$1"; }

wait_deploy() {   # $1 = job name
  dep=$(nomad job deployments -latest -t '{{.ID}}' "$1")
  nomad deployment status -monitor "$dep"     # non-zero exit if failed / auto-reverted
}

gate() {          # cluster-level check between groups
  # all BEs alive
  [ "$(sql "SHOW BACKENDS" | awk '$10!="true"' | wc -l)" -eq 0 ] || return 1   # adjust column for your version
  # let the returning group catch up on versions it missed while down
  sql 'ADMIN SET FRONTEND CONFIG ("disable_tablet_scheduler"="false")'
  until sql "SHOW PROC '/cluster_health/tablet_health'" | awk '{s+=$4} END{exit s!=0}'; do sleep 15; done
  sql 'ADMIN SET FRONTEND CONFIG ("disable_tablet_scheduler"="true")'
}

gate   # pre-flight: never start with an unhealthy cluster
for k in disable_balance disable_colocate_balance disable_tablet_scheduler; do
  sql "ADMIN SET FRONTEND CONFIG (\"$k\"=\"true\")"; done

# 1) BE, one server group at a time
for g in "${GROUPS[@]}"; do
  nomad-pack run ./packs/doris-be -f "groups/$g.hcl" --name "doris-be-$g" --var rollout_mode="$MODE"
  wait_deploy "doris-be-$g"; gate
done

# 2) FE, non-master first, master last
MASTER_DC=$(sql "SHOW FRONTENDS" | awk '$NF_ISMASTER=="true"{print $TAG}')   # map host -> dc in your env
for g in $(printf '%s\n' "${GROUPS[@]}" | grep -v "$MASTER_DC") "$MASTER_DC"; do
  nomad-pack run ./packs/doris-fe -f "groups/$g.hcl" --name "doris-fe-$g"
  wait_deploy "doris-fe-$g"
done

for k in disable_balance disable_colocate_balance disable_tablet_scheduler; do
  sql "ADMIN SET FRONTEND CONFIG (\"$k\"=\"false\")"; done
```

The `awk` column positions are placeholders. Check them against `SHOW BACKENDS`, `SHOW FRONTENDS` and `tablet_health` output from your Doris version, or use the FE HTTP API, which returns JSON.

## 5. Important points

- **The gate between groups is what makes this safe.** While dc1 was down, its replicas missed some loads. If you take dc2 down before dc1 catches up, some tablets have only one current replica, and loads can fail majority. Turning the tablet scheduler back on during the gate is my own addition to Doris's documented steps. It lets those missed versions get repaired, and turning it off again afterwards stops unwanted cloning during the next group's downtime.
- **Group mode costs one full DC of capacity and one replica of everything.** It's faster, but if a node in another DC fails during that window, some tablets have only one replica left. Use server mode for routine changes and group mode only when you need it.
- **FEs:** 3 followers means a quorum of 2, so one FE down is fine. Never roll FE and BE jobs at the same time in server mode. The script runs them one after another, so only one server is down at any moment.
- **Clients:** During the rolling upgrade process, connections to closed nodes will become invalid, causing request failures. For such businesses, it is recommended to add retry capability on the client side. Point clients at all 3 FEs through a load balancer or Consul DNS, not at a single FE.
- **Mixed versions:** test the version jump first. You can also upgrade one BE as a canary by running the script with `MODE=server` and stopping after the first allocation.
- **Only the script deploys.** If someone runs `nomad-pack run` by hand on two groups, they can take two DCs down at once. Put a Nomad ACL or a CI lock on these jobs.

Next, I can turn this into a complete pack (metadata, both templates, per-group variable files and the rollout script) as files you can drop into your repo.


# following user input
make sure it works for

1. three replicas in three different server group
2. can rolling upgrade by server group (at most server group down)
3. can rolling upgrade across server group (at most server down in cluster)
4. the deployment use local disk correctly, considering first time deploy and following rolling upgrade.

## response
I'll build the full pack and then test the Nomad side for real: a local multi-datacenter Nomad cluster with stand-in tasks, so placement, both rollout modes and the local-disk behaviour actually get checked rather than just written down. First, a check of what tooling I can get here.

Now the first-deploy pieces: volume creation, ACL policy, bootstrap and the cluster check.

Templates render. Now the test harness: fakes for `nomad-pack`, the Nomad API (`curl`) and Doris (`mysql`), which simulate the rollout and record exactly which servers are down at each moment.

I've built the pack and helper scripts in `doris-nomad.tar.gz`. All four requirements pass the offline tests (33 of 33). I couldn't run real Nomad or Doris here, though, so you still need one staging run before production.

The layout is one job per component per server group: `doris-be-dc1..3` and `doris-fe-dc1..3`. `scripts/rollout.sh` applies them one at a time, and nothing else should run `nomad-pack run` on them.

1. **Three replicas in three server groups:** each job is pinned to one group. Each BE registers itself in Doris with `tag.location` set to its group. Tables use `replication_allocation` with one replica per group; `sql/replica-policy.sql` has the statements. `scripts/check-cluster.sh --audit-tables` checks every partition.
2. **Rolling by server group (`--mode group`):** the whole group is replaced at once. The next group starts only after the deployment succeeds and Doris reports zero unhealthy tablets. In the simulation, three servers were down at the peak, never from two groups.
3. **Rolling across groups (`--mode server`):** one server at a time in the whole cluster, in the order BE dc1, dc2, dc3, then the FE followers, then the master FE. In the simulation, at most one server was down at any time. Switching between the two modes changes only `max_parallel`, so it restarts nothing.
4. **Local disk:**
   - Volumes are created on every node before the first deploy, and `sticky` keeps each member on its own node and data.
   - On first deploy, the FE in dc1 creates the cluster, the other FEs join it as followers, and each BE registers itself.
   - On a rolling upgrade or restart, a member whose data is already on its volume just restarts.
   - A rebuilt node with an empty volume joins the cluster again and never starts a second cluster.
   - A replacement FE or BE waits until the old one has released its volume, so two copies never write to the same disk.

The simulator caught a design point worth knowing. Within one group, servers can restart back to back with no wait, because no tablet has two replicas in the same group. Between groups, the script has to let the group that just came back catch up first. A test that removes this wait confirms the simulator catches it.

What the tests used:
- **Templates:** a stand-in renderer using the same template engine as nomad-pack. All 12 job variants rendered and passed checks.
- **Startup scripts:** the real in-container scripts ran against a fake Doris.
- **Rollout:** the real `rollout.sh` ran against a simulated Nomad and Doris.

Before production, on one staging cluster:
- Run `nomad-pack render` with your nomad-pack version, then `nomad job validate` on the output.
- Check the Doris image paths, that the images include `flock`, and that the column names my scripts read from Doris match your version.
- Kill one BE and confirm it comes back on the same node, then run both rollout modes while a load is running.

The README lists these steps, plus the steps for replacing a dead node.

# following user input
one more question, does doris client user need any deployment knowledge or paramters to create or alter table on doris?

## response
Only if they create the database themselves. If an admin creates each database with the replica policy, users can write ordinary `CREATE TABLE` and `ALTER TABLE` statements and never need to know about server groups, tags, nodes or Nomad.

**Without a database default, a plain `CREATE TABLE` will fail.** Doris converts the default replica setting into a location tag: `"replication_num" = "3"` will be automatically converted to `"replication_allocation" = "tag.location.default:3"`. In this setup every BE is tagged `dc1`, `dc2` or `dc3`, so no BE carries the `default` tag. A table created without the property, or with `replication_num = 3`, will therefore be rejected because Doris finds no eligible backends. That is safe but confusing for users.

**The fix is a policy on each database, owned by the admin.** Doris supports this directly. Its docs show a database created with a replica policy, and note that later CREATE TABLE statements for table2, table3, and table4 do not need to specify replication_allocation and automatically inherit the policy of db1.

```sql
-- DBA, once per database
CREATE DATABASE sales PROPERTIES (
  "replication_allocation" = "tag.location.dc1: 1, tag.location.dc2: 1, tag.location.dc3: 1"
);

-- users: plain DDL, no deployment knowledge
CREATE TABLE sales.orders (id BIGINT, dt DATE, amount DECIMAL(18,2))
DUPLICATE KEY(id) PARTITION BY RANGE(dt) () DISTRIBUTED BY HASH(id) BUCKETS 16;
ALTER TABLE sales.orders ADD COLUMN channel VARCHAR(32);
```

Two cautions:
- Changing the replica distribution policy of a Database does not affect existing Tables. Set the policy when you create the database, and migrate older tables as shown in `sql/replica-policy.sql`.
- That example comes from the Doris 4.x docs. Check that `CREATE DATABASE ... PROPERTIES ("replication_allocation" = ...)` works on your Doris version.

**What users still need to know:**
- **Connection:** only the FE address (a load balancer or the `doris-fe-query` service on port 9030) and their own account.
- **Never set** `replication_num` or `replication_allocation` in their own DDL. A table-level value overrides the database default and can break the one-replica-per-group placement. The same applies to `dynamic_partition.replication_allocation` and `dynamic_partition.replication_num`; leave them unset so partitions follow the table.
- **Ordinary schema changes** don't involve replicas, so they need no extra knowledge. That covers adding, dropping or modifying columns, adding partitions, renaming and indexes.

**Keep users from breaking this:**
- Only admins get `CREATE DATABASE`. Users get table-level privileges inside existing databases.
- Run `scripts/check-cluster.sh --audit-tables` daily or in CI. It reports any partition whose replicas are not one per group, which catches anyone who overrode the policy.
- Doris may have an FE setting that forces one placement on every table. I couldn't confirm one in the docs, so don't rely on it.

I can add a `create-database.sh` to the pack that creates databases with the policy. I'd also correct `sql/replica-policy.sql`, which currently suggests `ALTER DATABASE` as the main route.