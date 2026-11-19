#!/usr/bin/env python3
"""assert_job.py <render_dir> <be|fe> <group> <server|group> <group_var_file>"""
import json
import re
import sys
from pathlib import Path

import hcl2

out, comp, group, mode, varfile = sys.argv[1:6]
files = list(Path(out).glob("*.nomad"))
assert len(files) == 1, f"exactly one job per render, got {files}"
text = files[0].read_text()

# leftovers / things Nomad or consul-template would mis-parse
outside_scripts = re.sub(r"<<EOS_DORIS\n.*?\nEOS_DORIS", "", text, flags=re.S)
assert "[[" not in outside_scripts and "]]" not in outside_scripts, "unrendered pack delimiters"
assert "%{" not in text, "HCL template directive %{ in job"
for m in re.finditer(r"\$\{([^}]*)\}", text):
    assert re.match(r"(NOMAD_|node\.)", m.group(1)), f"HCL would try to interpolate ${{{m.group(1)}}}"
for block in re.findall(r"<<EOS_DORIS\n(.*?)\nEOS_DORIS", text, re.S):
    assert "{{" not in block and "}}" not in block, "consul-template delimiters inside an embedded script"


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


job = norm(hcl2.loads(text))["job"][0]
jid = next(iter(job))
j = job[jid]
assert jid == f"doris-{comp}-{group}", jid
assert j["datacenters"] == [group], j["datacenters"]
cons = {c["attribute"]: c["value"] for c in j["constraint"]}
assert cons["${node.meta.server_group}"] == group, cons
assert cons[f"${{node.meta.doris_{comp}}}"] == "true", cons

g = j["group"][0][comp]
upd = g["update"][0]
be_count = int(re.search(r"be_count\s*=\s*(\d+)", Path(varfile).read_text()).group(1))
count = int(g["count"])
want_count = be_count if comp == "be" else 1
assert count == want_count, (count, want_count)
want_maxp = be_count if (comp == "be" and mode == "group") else 1
assert int(upd["max_parallel"]) == want_maxp, (upd["max_parallel"], want_maxp)
assert int(upd["canary"]) == 0 and upd["auto_revert"] is True and upd["health_check"] == "checks"

vol = next(iter(g["volume"][0].values()))
assert vol["type"] == "host" and vol["sticky"] is True, vol
assert vol["access_mode"] == "single-node-writer"
disc = g["disconnect"][0]
assert disc["replace"] is False and disc["reconcile"] == "keep_original"
ports = g["network"][0]["port"]
assert all("static" in next(iter(p.values())) for p in ports), "all ports static"
if comp == "be":
    assert any(c.get("operator") == "distinct_hosts" for c in g.get("constraint", []))
tasks = {next(iter(t)): next(iter(t.values())) for t in g["task"]}
main = tasks[comp]
assert main["volume_mount"][0]["volume"] == next(iter(g["volume"][0]))
helper = tasks["register" if comp == "be" else "fe-init"]
hook = helper["lifecycle"][0]["hook"]
assert hook == ("poststart" if comp == "be" else "prestart"), hook
print(f"{jid}: count={count} max_parallel={upd['max_parallel']} sticky volume={vol['source']} ok")
