"""Resolve pack variables like nomad-pack: defaults from variables.hcl, then -f files
in order, then --var k=v. Prints JSON.  python3 packvars.py <pack_dir> [-f file]... [--var k=v]..."""
import json
import sys

import hcl2


def norm(v):
    """python-hcl2 (v5+) keeps HCL quoting; turn it back into plain values."""
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


def load(path):
    with open(path) as fh:
        return norm(hcl2.load(fh))


def main(argv):
    pack = argv[0]
    decl = {}
    for block in load(f"{pack}/variables.hcl").get("variable", []):
        for name, body in block.items():
            decl[name] = body
    vals = {k: v.get("default") for k, v in decl.items()}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("-f", "--var-file"):
            for k, v in load(argv[i + 1]).items():
                if k not in decl:
                    sys.exit(f"variable {k} in {argv[i+1]} not declared")
                vals[k] = v
            i += 2
        elif a == "--var":
            k, v = argv[i + 1].split("=", 1)
            if k not in decl:
                sys.exit(f"variable {k} not declared")
            t = str(decl[k].get("type", "string"))
            vals[k] = int(v) if "number" in t else v
            i += 2
        else:
            sys.exit(f"bad arg {a}")
    print(json.dumps(vals))


if __name__ == "__main__":
    main(sys.argv[1:])
