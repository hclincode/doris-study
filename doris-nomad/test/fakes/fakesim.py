#!/usr/bin/env python3
"""Fake nomad-pack / curl (Nomad API) / mysql (Doris FE) backed by one state dir ($SIM).

What it simulates, so the orchestration can be checked end to end:
  * nomad-pack run renders the pack (same renderer as the render tests), reads count and
    update.max_parallel from the rendered HCL, and if the job changed rolls it exactly the
    way Nomad does for a destructive update: batches of max_parallel allocations
    (stop -> start on the same node, because the volume is sticky).
    Every stop/start is written to $SIM/events.log.
  * Doris: after a BE group was down its replicas miss versions -> tablets unhealthy until
    the tablet scheduler is enabled (disable_tablet_scheduler=false). Taking another group
    down while that repair is pending is logged as a VIOLATION.
  * ADMIN SET FRONTEND CONFIG must hit the master FE; otherwise VIOLATION.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import hcl2

SIM = Path(os.environ["SIM"])
ROOT = Path(__file__).resolve().parents[2]
GROUPS = os.environ.get("DORIS_GROUPS", "dc1 dc2 dc3").split()
MASTER_GROUP = os.environ.get("SIM_MASTER_GROUP", "dc2")
BE_PER_GROUP = 3


def st():
    p = SIM / "state.json"
    if p.exists():
        return json.loads(p.read_text())
    s = {"jobs": {}, "cfg": {"disable_balance": "false", "disable_colocate_balance": "false",
                             "disable_tablet_scheduler": "false"}, "repair_pending": []}
    save(s)
    return s


def save(s):
    (SIM / "state.json").write_text(json.dumps(s, indent=1))


def ev(line):
    with open(SIM / "events.log", "a") as fh:
        fh.write(line + "\n")


def fe_ip(g):
    return f"10.0.{GROUPS.index(g) + 1}.10"


def be_ip(g, i):
    return f"10.0.{GROUPS.index(g) + 1}.{20 + i}"


# ------------------------------------------------------------------ nomad-pack
def norm(v):
    if isinstance(v, dict):
        return {norm(k): norm(x) for k, x in v.items() if not str(k).startswith("__")}
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, str) and len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        try:
            return json.loads(v, strict=False)
        except ValueError:  # heredocs
            return v[1:-1]
    return v


def nomad_pack(argv):
    cmd, pack, rest = argv[0], argv[1], argv[2:]
    name, pv = None, []
    i = 0
    while i < len(rest):
        if rest[i] == "--name":
            name = rest[i + 1]
        elif rest[i] in ("-f", "--var"):
            pv += [rest[i], rest[i + 1]]
        i += 2
    vars_json = subprocess.check_output([sys.executable, str(ROOT / "test/packvars.py"), pack] + pv)
    (SIM / "vars.json").write_bytes(vars_json)
    out = SIM / "render" / name
    subprocess.check_call([os.environ.get("PACKRENDER", "/tmp/packrender"), pack, str(SIM / "vars.json"), str(out)])
    files = list(out.glob("*.nomad"))
    assert len(files) == 1, f"expected exactly one job from one render, got {files}"
    text = files[0].read_text()
    job = norm(hcl2.loads(text))["job"][0]
    job_id = next(iter(job))
    assert job_id == name, f"job id {job_id} != deployment name {name}"
    grp = job[job_id]["group"][0]
    gname = next(iter(grp))
    count = int(grp[gname]["count"])
    maxp = int(grp[gname]["update"][0]["max_parallel"])
    group = job[job_id]["constraint"][0]["value"]
    comp = gname

    if cmd == "plan":
        print(f"plan {job_id}: count={count} max_parallel={maxp}")
        return 0

    s = st()
    j = s["jobs"].get(job_id)
    # the update block is not part of what makes an update destructive
    spec = "\n".join(l for l in text.splitlines() if "max_parallel" not in l)
    if j and j["spec"] == spec and j["text"] == text:
        ev(f"RUN {job_id} unchanged")
        return 0
    first = j is None
    destructive = first or j["spec"] != spec
    ver = 0 if first else j["version"] + 1
    s["jobs"][job_id] = {"version": ver, "spec": spec, "text": text,
                         "deployments": (j or {}).get("deployments", [])}
    save(s)
    ev(f"RUN {job_id} v{ver} count={count} max_parallel={maxp} first={first}")
    nodes = [f"{group}-fe"] if comp == "fe" else [f"{group}-be{i}" for i in range(count)]
    if not first and destructive:
        for b in range(0, len(nodes), maxp):
            batch = nodes[b:b + maxp]
            s = st()
            for n in batch:
                # one replica per group: only ANOTHER group still repairing makes this unsafe
                other = [x for x in s["repair_pending"] if x != group]
                if comp == "be" and other:
                    ev(f"VIOLATION {n} stopped while replicas of {other} still repairing")
                ev(f"DOWN {n}")
            for n in batch:
                ev(f"UP {n}")
            if comp == "be" and group not in s["repair_pending"]:
                s["repair_pending"].append(group)
            save(s)
    elif first:
        for n in nodes:
            ev(f"START {n}")
    s = st()
    s["jobs"][job_id]["deployments"].append({"ID": f"{job_id}-{ver}", "JobVersion": ver,
                                             "Status": "successful", "StatusDescription": "ok",
                                             "CreateIndex": ver + 1})
    s["jobs"][job_id]["version"] = ver
    s["jobs"][job_id]["spec"], s["jobs"][job_id]["text"] = spec, text
    save(s)
    return 0


# ------------------------------------------------------------------ curl (Nomad API)
def curl(argv):
    url = argv[-1]
    path = url.split("/v1/", 1)[1]
    s = st()
    parts = path.split("/")
    if parts[0] == "job":
        j = s["jobs"].get(parts[1])
        if j is None:
            sys.stderr.write("404\n")
            return 22
        if len(parts) == 2:
            print(json.dumps({"ID": parts[1], "Version": j["version"]}))
        elif parts[2] == "deployments":
            print(json.dumps(j["deployments"]))
        elif parts[2] == "allocations":
            print("[]")
        return 0
    if parts[0] == "service":
        print(json.dumps([{"Address": fe_ip(g), "Port": 9030, "Tags": [g]} for g in GROUPS]))
        return 0
    sys.stderr.write(f"unhandled {path}\n")
    return 22


# ------------------------------------------------------------------ mysql (Doris)
def table(cols, rows):
    print("\t".join(cols))
    for r in rows:
        print("\t".join(str(x) for x in r))


def mysql(argv):
    host = argv[argv.index("-h") + 1]
    sql = argv[argv.index("-e") + 1]
    s = st()
    master = fe_ip(MASTER_GROUP)
    if sql == "SHOW FRONTENDS":
        table(["Name", "Host", "EditLogPort", "HttpPort", "QueryPort", "RpcPort", "Role", "IsMaster",
               "Alive", "Join", "Version"],
              [[f"fe_{g}", fe_ip(g), 9010, 8030, 9030, 9020, "FOLLOWER",
                str(fe_ip(g) == master).lower(), "true", "true", "x"] for g in GROUPS])
    elif sql == "SHOW BACKENDS":
        table(["BackendId", "Host", "HeartbeatPort", "Alive", "Tag", "Version"],
              [[i, be_ip(g, i), 9050, "true", '{"location" : "%s"}' % g, "x"]
               for g in GROUPS for i in range(BE_PER_GROUP)])
    elif "tablet_health" in sql:
        if s["repair_pending"] and s["cfg"]["disable_tablet_scheduler"] == "false":
            ev(f"REPAIRED {s['repair_pending']}")
            s["repair_pending"] = []
            save(s)
        bad = 5 if s["repair_pending"] else 0
        table(["DbId", "DbName", "TabletNum", "HealthyNum"],
              [[1, "db1", 100, 100 - bad], ["Total", "Total", 100, 100 - bad]])
    elif sql.startswith("ADMIN SHOW FRONTEND CONFIG LIKE"):
        k = sql.split("'")[1]
        table(["Key", "Value", "Type", "IsMutable"], [[k, s["cfg"][k], "boolean", "true"]])
    elif sql.startswith("ADMIN SET FRONTEND CONFIG"):
        k = sql.split('"')[1]
        v = sql.split('"')[3]
        if host != master:
            ev(f"VIOLATION admin set {k} sent to non-master {host}")
        s["cfg"][k] = v
        save(s)
        ev(f"CFG {k}={v}")
    else:
        sys.stderr.write(f"fake mysql: unhandled {sql}\n")
        return 1
    return 0


if __name__ == "__main__":
    tool = os.path.basename(sys.argv[0])
    fn = {"nomad-pack": nomad_pack, "curl": curl, "mysql": mysql}[tool]
    sys.exit(fn(sys.argv[1:]))
