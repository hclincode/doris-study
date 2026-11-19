ref: [Nomad stateful service on local disk](https://claude.ai/share/48565109-0188-496b-9211-525156027441)

# previous discussions
(user) when using nomad to deploy and manage stateful servie with requirement using local disk. what's the best way to manage, plan with nomad-pack. please also consider rolling upgrade for distributed system with zero down time

Short version: on Nomad 1.10 or later, use **dynamic host volumes with `sticky = true`** and run the cluster as **one task group with `count = N`**. Roll it with `max_parallel = 1` and a health check that only passes once a member has rejoined the cluster. nomad-pack should only template the job. Create the volumes separately, before the job, because they last longer than any one deploy.

## 1. Choosing the storage type

| Option | When to use it | Downsides |
|---|---|---|
| **Dynamic host volumes + sticky** (best choice, 1.10+) | Local NVMe or SSD, managed through the API or CLI | The data lives on one node, so that member is tied to that node |
| Static host volumes (in the client config) | Older clusters | Adding a volume means editing the client config and restarting the agent; you have to pin members to nodes yourself |
| CSI + `per_alloc` | Network storage (EBS, Ceph, SAN) | Not really local disk; slower and more moving parts |
| `ephemeral_disk { sticky = true, migrate = true }` | Caches, data you can rebuild | Best effort only. Don't rely on it for a database |

Since 1.10, host volumes no longer need to be defined as part of the Nomad client configuration, removing the need to restart the client agent as new volumes are added. Volumes are created by a plugin, so you can provision real storage. For example, they can now optionally be created with more detailed characteristics like their minimum and maximum capacities, capabilities, and custom provisioning parameters, and the plugin can drive LVM, ZFS or local NVMe.

How sticky volumes behave: during the deployment the scheduler associates its ID with the task group that uses it. Stateful deployments require that any allocations belonging to that task group must be places or replaced on nodes that have this volume ID available. Also note that scaling jobs down does not delete unused volumes, nor does it touch the data present on them. That is safe, but you have to clean up old volumes yourself.

## 2. Topology: one task group, not one group per member

This is the most common mistake. **`update.max_parallel` applies per task group, and separate groups roll out in parallel.** Suppose you write `group "db-0"`, `group "db-1"` and `group "db-2"` in one job, each with `max_parallel = 1`. A destructive change then replaces all three members at once, and the cluster goes down.

There are two correct patterns:

- **A (recommended): one group with `count = N` and sticky volumes.** Each member's identity is `${NOMAD_ALLOC_INDEX}` (0..N-1). A replacement allocation keeps the same index, so it also keeps its volume. Members find each other through Consul or Nomad service discovery.
- **B: one job per member** (for example `db-0`, `db-1`, `db-2`, each with `count = 1` and a fixed node). This gives you explicit per-member config and fixed placement. The cost is that your CI pipeline has to roll them one at a time: run the job, wait for its deployment to succeed, then move to the next.

Pattern A sketch:

```hcl
job "[[ .my.job_name ]]" {
  type = "service"

  group "db" {
    count = [[ .my.replicas ]]          # 3 or 5, an odd number for quorum

    constraint { operator = "distinct_hosts"  value = "true" }
    spread     { attribute = "${node.datacenter}" }   # or rack/AZ meta

    volume "data" {
      type            = "host"
      source          = "[[ .my.volume_name ]]"
      sticky          = true
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

    # Don't replace a member just because its node briefly lost contact
    disconnect {
      lost_after = "10m"
      replace    = false
      reconcile  = "keep_original"
    }
    reschedule { attempts = 0  unlimited = false }   # let restarts handle it; avoid moving data around
    restart    { attempts = 3  interval = "10m"  delay = "15s"  mode = "delay" }

    update {
      max_parallel      = 1
      health_check      = "checks"
      min_healthy_time  = "[[ .my.min_healthy_time ]]"   # e.g. 60s: time for it to catch up
      healthy_deadline  = "15m"
      progress_deadline = "30m"
      auto_revert       = true
      canary            = 0     # canaries need an extra volume and member; usually avoid for quorum systems
      stagger           = "30s"
    }

    network { port "client" {}  port "peer" {} }

    service {
      name = "[[ .my.job_name ]]"
      port = "client"
      check {
        type     = "http"
        path     = "/health/ready"   # ready = joined the cluster AND caught up on replication
        interval = "5s"
        timeout  = "2s"
      }
    }

    task "db" {
      driver       = "docker"
      kill_signal  = "SIGTERM"
      kill_timeout = "120s"          # time to hand off leadership and flush
      shutdown_delay = "10s"         # deregister from Consul before SIGTERM so clients drain

      volume_mount { volume = "data"  destination = "/var/lib/db" }

      env { NODE_ID = "[[ .my.job_name ]]-${NOMAD_ALLOC_INDEX}" }
    }
  }
}
```

## 3. Laying out the nomad-pack

```
packs/mydb/
  metadata.hcl
  variables.hcl          # replicas, volume_name, image, update timings, node_pool
  templates/
    _helpers.tpl
    mydb.nomad.tpl       # job only
  volumes/
    volume.hcl.tpl       # rendered separately, NOT submitted by `run`
```

Keep volume creation out of `nomad-pack run`. Volumes outlive deployments, and `nomad-pack destroy` must never take your data with it. Create one volume per node, as many as `replicas`, ahead of time. You can use `nomad volume create`, or render the volume template and loop over it in CI:

```hcl
name      = "mydb-data"
type      = "host"
plugin_id = "lvm-thin"           # or the built-in "mkdir" for a plain directory
node_pool = "stateful"
capacity_min = "200G"
capability { access_mode = "single-node-writer"  attachment_mode = "file-system" }
```

Run this on each target node (you can pin with `node_id`), or manage the volumes with Terraform. Give the stateful nodes their own `node_pool` so other workloads can't use them.

Workflow:

```bash
nomad-pack render ./packs/mydb -f prod.hcl        # look at the HCL
nomad-pack plan   ./packs/mydb -f prod.hcl        # runs a `nomad job plan` under the hood
nomad-pack run    ./packs/mydb -f prod.hcl
nomad job deployment status -monitor <id>         # or poll in CI; fail if not "successful"
```

In CI, treat the plan output as a gate. A diff that shows **"create/destroy update"** is a destructive update and starts a rolling restart, so have it require approval. **"in-place update"** (for example changing only service tags or metadata) does not restart anything. If the plan ever shows allocations *placed on a new node* for this group, stop: the scheduler couldn't find the sticky volume.

## 4. Zero-downtime rolling upgrades

Nomad can only promise to replace one member at a time. Whether that means zero downtime depends on what the application does around it:

1. **Quorum headroom.** Use N = 3 to tolerate 1 failure, or 5 to tolerate 2. With `max_parallel = 1` one member is down during each step, so never run 3 members when one of them is already unhealthy. Add a pre-flight step in CI that checks cluster health through the database's own API before `run`.
2. **Health means caught up, not port open.** The `/ready` check should pass only after the member has rejoined, synced, and its replication lag is under a threshold. Combined with `min_healthy_time`, that is what keeps the next member from being stopped too early.
3. **Graceful exit.** `shutdown_delay` deregisters the service so clients stop sending traffic. The app should then catch SIGTERM, transfer leadership if it holds it, and flush. Set `kill_timeout` longer than the worst-case handoff. Roll the leader last if you can; some teams add a step that transfers leadership before each deploy.
4. **Clients must cope with one member being gone.** Give them multiple endpoints and retries (or a Consul DNS name), and make sure they tolerate a leader election. Without this, a single replaced member still causes errors.
5. **Version compatibility.** A rolling upgrade means old and new versions run side by side. Check the database's upgrade path. Many systems require one minor version at a time and need a feature-flag or protocol bump after every member is upgraded. Do that in a separate deploy.
6. **`auto_revert = true`** returns you to the last stable job version if a member fails its health check. Reverting only changes the image and config, not the data, so data-format migrations must be backward compatible or treated as one-way steps.

## 5. Node maintenance (kernel and OS patching)

Draining a node doesn't work well when the data lives on that node. The member can't move anywhere because its sticky volume is still there. For short maintenance windows:

```bash
nomad node eligibility -disable <node>
# stop just this alloc (or let the reboot take it), patch, reboot
nomad node eligibility -enable <node>      # the alloc comes back to the same volume
```

Do this for one node at a time and check cluster health between nodes. Because `disconnect.replace = false`, Nomad won't start a replacement member elsewhere while the node is down.

To retire a node permanently, scale up to N+1 so a new member starts on a new node with a new volume. Wait for it to sync, remove the old member from the database cluster, then delete the old volume.

Want me to put this on a Whiteboard?

(user) my case is closed to the first option. tell me more but focus

I've taken "first option" to mean the setup from my earlier answer: one task group with `count = N` and sticky dynamic host volumes. Below is how that setup behaves day to day, including where it breaks.

## 1. How sticky claims work

- When an allocation is first placed, the scheduler associates a volume ID with the task group. The group's allocations must be placed or replaced on nodes where that volume ID is available. Nomad stores these associations in its state store, along with job IDs, volume names, and namespaces.
- So you create **one volume per node, all with the same `name`**, and the job refers to that name. Each allocation ends up holding a specific volume ID on a specific node.
- From then on, each member is pinned to its node, and Nomad enforces that for you.

**Provisioning rules:**

```bash
# one per stateful node, same name, plus 1 spare node/volume for recovery
for node in $STATEFUL_NODES; do
  nomad volume create -node "$node" volume.hcl     # name = "mydb-data"
done
```

- Have **at least N+1 volumes** for `count = N`. The spare is what makes recovery from a dead node quick (section 4).
- Put these nodes in a separate `node_pool` and have the job use `node_pool = "stateful"`. Then no other job can claim the volumes.
- `distinct_hosts` is still worth keeping. It guards the first placement, before any claims exist.

## 2. Member identity and joining the cluster

`NOMAD_ALLOC_INDEX` keeps its value when an allocation is replaced, which works well as an identity. Even so, **make the data directory the real source of identity**:

```bash
# entrypoint.sh
ID_FILE=/var/lib/db/member-id
[ -f "$ID_FILE" ] || echo "mydb-${NOMAD_ALLOC_INDEX}" > "$ID_FILE"
export MEMBER_ID=$(cat "$ID_FILE")
```

When a member is rebuilt onto a spare volume, it starts with an empty disk and a new ID file. The database then sees it as a new member, which is correct, instead of mistaking it for an old member that has lost its data.

**Peer addressing.** The member is pinned to its node anyway, so give the peer port a static port number. Its peer address (node IP plus that port) then stays the same across restarts and upgrades:

```hcl
network {
  port "peer"   { static = 7000 }
  port "client" { static = 7001 }   # optional; dynamic is fine if clients use Consul
}
```

**Bootstrap and discovery.** On the first deploy all N members start at once, so the database must keep retrying the join, or support something like `bootstrap_expect`. Render the peer list from service discovery:

```hcl
template {
  destination = "local/peers.conf"
  change_mode = "noop"          # don't restart members when peers change; the DB handles membership
  data = <<EOT
{{ range nomadService "mydb-peer" }}peer = "{{ .Address }}:{{ .Port }}"
{{ end }}
EOT
}
```

Use `change_mode = "noop"`. Otherwise a rolling upgrade restarts **every** member each time one member re-registers, which wipes out the one-at-a-time rollout.

## 3. How a rolling upgrade actually runs

With sticky single-writer volumes, a destructive update replaces each member **on the same node**: the old allocation stops and releases its volume, then the new one starts and mounts it. Each member is therefore fully down for stop time + start time + catch-up time. Zero downtime only holds if the cluster can keep running with one member down. In practice:

**Settings in the `update` block:**

```hcl
update {
  max_parallel      = 1
  canary            = 0        # see below
  health_check      = "checks"
  min_healthy_time  = "60s"    # longer than your worst catch-up/compaction blip
  healthy_deadline  = "15m"    # long enough to replay WAL / sync after downtime
  progress_deadline = "30m"
  auto_revert       = true
}
```

**No canaries.** A canary needs another volume to claim. With exactly N volumes it can't be placed. With a spare volume it would join as an extra member, which changes quorum math in a consensus system. Test the new version in staging, and treat `auto_revert` as the safety net.

**Gate on readiness, not liveness.** Use a script check that asks the database itself:

```hcl
check {
  name     = "member-ready"
  type     = "script"
  command  = "/usr/local/bin/ready.sh"   # exit 0 only if: joined, quorum seen, lag < threshold
  interval = "5s"
  timeout  = "3s"
  on_update = "require_healthy"
}
```

If the check only tests the port, Nomad marks the member healthy while it is still catching up. The next member then stops, and you can lose quorum.

**Leader handoff.** Nomad doesn't let you choose the order allocations are replaced in, so handle the leader inside the app's shutdown:

```hcl
task "db" {
  shutdown_delay = "10s"     # deregister service → clients move away first
  kill_signal    = "SIGTERM" # handler: if leader → transfer leadership, then flush & exit
  kill_timeout   = "120s"
}
```

**Pre-flight in CI.** Before `nomad-pack run`, check that all N members are healthy and replication lag is near zero. If one member is already degraded, an N=3 cluster drops to 1 of 3 during the rollout.

**Two different update paths:**
- Changing the image, environment, resources or a template that triggers a restart is destructive and causes a rolling restart.
- Changing service tags or check settings is usually in-place, with no restart.

Your CI should read `nomad-pack plan` output and require approval for any **create/destroy update** on this group.

## 4. Failure handling

| Event | What Nomad does | What you do |
|---|---|---|
| Process crash | `restart` block restarts it on the same node and volume | Nothing |
| Node reboot or short outage | With `disconnect { replace = false, reconcile = "keep_original" }`, it waits | Nothing; the member resyncs |
| Node gone for good | If no node has the required volume ID, for example because the node is down or disconnected, Nomad creates a blocked evaluation. The allocation stays pending. | Manual recovery (below) |

**Recovering from a dead node:**

1. Remove the dead member from the database cluster (e.g. `member remove`) so quorum is calculated over N-1.
2. Delete that task group's volume claim. You can list and delete task group host volume claims through the API. After a claim is deleted, Nomad assigns a different volume ID if the old one is unavailable and another feasible host volume with a matching name exists. This is why you keep a spare volume.
3. The new allocation lands on the spare node with an empty disk and a new member ID (section 2). It joins and copies the data from its peers.
4. Clean up the dead node's volume record, and provision a new spare.

HashiCorp reserves claim deletion for emergencies and debugging; the docs advise using claim deletion only in operational emergencies or while debugging node problems. Write it up as a runbook step, not something that runs automatically.

**Planned maintenance on a node** (one at a time): run `nomad node eligibility -disable`, then patch and reboot. The allocation returns to the same volume, and you re-enable the node. Avoid `node drain` here, because the member has nowhere to move.

**Scaling down** removes members but does not delete unused volumes or the data on them. Remove the member from the database cluster *before* lowering `count`, and wipe the old volume before it is reused. Otherwise a later scale-up could claim it with stale data.

## 5. What to make variables in the pack

```hcl
# variables.hcl
variable "replicas"          { default = 3 }
variable "volume_name"       { default = "mydb-data" }
variable "node_pool"         { default = "stateful" }
variable "image"             {}
variable "min_healthy_time"  { default = "60s" }
variable "healthy_deadline"  { default = "15m" }
variable "kill_timeout"      { default = "120s" }
variable "peer_port"         { default = 7000 }
```

Keep volume creation and the claim-recovery runbook **outside** the pack. Day-to-day changes go through `render → plan → run → monitor the deployment`. Volume lifecycle and claim deletion are separate operator tasks.

If you tell me which database or system this is (etcd, Consul, Kafka/KRaft, CockroachDB, Postgres with Patroni…), I can fill in the actual readiness check, leader-handoff command and member-removal steps for it.



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