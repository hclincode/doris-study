#!/usr/bin/env python3
"""Assert the rollout invariants from $SIM/events.log.
   check_events.py <mode: server|group> <expect_master_group> [--expect-no-roll]"""
import os
import sys
from pathlib import Path

mode, master = sys.argv[1], sys.argv[2]
no_roll = "--expect-no-roll" in sys.argv
lines = (Path(os.environ["SIM"]) / "events.log").read_text().splitlines()
errors = []

viol = [l for l in lines if l.startswith("VIOLATION")]
errors += viol

down, peak, peak_groups = set(), 0, set()
order = []
cfg_true_before_first_down = None
cfg = {}
for l in lines:
    kind, *rest = l.split()
    if kind == "CFG":
        k, v = rest[0].split("=")
        cfg[k] = v
    if kind == "DOWN":
        n = rest[0]
        if cfg_true_before_first_down is None:
            cfg_true_before_first_down = all(cfg.get(k) == "true" for k in
                                             ("disable_balance", "disable_colocate_balance"))
        down.add(n)
        groups = {x.split("-")[0] for x in down}
        if len(down) > peak:
            peak = len(down)
        peak_groups |= groups if len(groups) > 1 else set()
        if len(groups) > 1:
            errors.append(f"two server groups down at once: {sorted(down)}")
        comp_grp = ("fe" if n.endswith("-fe") else "be", n.split("-")[0])
        if not order or order[-1] != comp_grp:
            order.append(comp_grp)
    if kind == "UP":
        down.discard(rest[0])

if no_roll:
    if any(l.startswith("DOWN") for l in lines):
        errors.append("expected no restarts, but something went down")
else:
    want_peak = 1 if mode == "server" else 3
    if peak != want_peak:
        errors.append(f"peak simultaneous servers down = {peak}, expected {want_peak} for mode={mode}")
    be = [g for c, g in order if c == "be"]
    fe = [g for c, g in order if c == "fe"]
    if be != ["dc1", "dc2", "dc3"]:
        errors.append(f"BE group order {be}")
    if fe and fe[-1] != master:
        errors.append(f"FE master group {master} not last: {fe}")
    if be and fe and [c for c, _ in order].index("fe") < len(be):
        errors.append(f"FE rolled before all BE groups: {order}")
    if not cfg_true_before_first_down:
        errors.append("balance not disabled before the first node went down")
    if any(cfg.get(k) != "false" for k in ("disable_balance", "disable_colocate_balance", "disable_tablet_scheduler")):
        errors.append(f"FE config not restored at the end: {cfg}")

print(f"mode={mode} peak_down={peak} order={order} final_cfg={cfg}")
if errors:
    print("FAILED:\n  " + "\n  ".join(errors))
    sys.exit(1)
print("OK")
