#!/usr/bin/env python3
"""Fake mysql for the in-container scripts (fe-init.sh, be-register.sh).
State in $DSIM: reachable (file present = FE answers), frontends.tsv, backends.tsv, sql.log"""
import os
import sys
from pathlib import Path

D = Path(os.environ["DSIM"])
sql = sys.argv[sys.argv.index("-e") + 1]
host = sys.argv[sys.argv.index("-h") + 1]
with open(D / "sql.log", "a") as fh:
    fh.write(f"{host} {sql}\n")
if not (D / "reachable").exists():
    sys.stderr.write("ERROR 2003: can't connect\n")
    sys.exit(1)

fe = D / "frontends.tsv"
be = D / "backends.tsv"
if sql == "SHOW FRONTENDS":
    print("Name\tHost\tEditLogPort\tIsMaster\tAlive")
    if fe.exists():
        print(fe.read_text(), end="")
elif sql == "SHOW BACKENDS":
    print("BackendId\tHost\tHeartbeatPort\tAlive\tTag")
    if be.exists():
        print(be.read_text(), end="")
elif sql.startswith("ALTER SYSTEM ADD FOLLOWER"):
    h, p = sql.split('"')[1].split(":")
    with open(fe, "a") as fh:
        fh.write(f"new\t{h}\t{p}\tfalse\tfalse\n")
elif sql.startswith("ALTER SYSTEM ADD BACKEND"):
    h, p = sql.split('"')[1].split(":")
    g = sql.split('"')[5]
    with open(be, "a") as fh:
        fh.write(f'9\t{h}\t{p}\ttrue\t{{"location" : "{g}"}}\n')
elif sql.startswith("ALTER SYSTEM MODIFY BACKEND"):
    pass
else:
    sys.stderr.write(f"unhandled {sql}\n")
    sys.exit(1)
