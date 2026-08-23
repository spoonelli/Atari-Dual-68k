#!/usr/bin/env python3
"""Cross-check the Verilog->VHDL instantiation of escape_core.

The MiSTer glue instantiates a VHDL entity from Verilog. Quartus only validates
that boundary well into a ~30 minute compile, and a typo'd or renamed port is
exactly what happens when the shared machine RTL moves under the port (as it
did at BUILD 103, which added five ee_* ports). This check takes a second and
fails immediately.

It verifies:
  * every port named in the instantiation actually exists on the entity, and
  * every entity input WITHOUT a VHDL default is connected.

Outputs may be left open on purpose (the Pocket's debug bundle is ~50 ports
this build has no use for), so unconnected outputs are reported, not failed.

Usage: check_ports.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VHDL = os.path.join(HERE, "..", "fpga", "core", "rtl", "escape_core.vhd")
VLOG = os.path.join(HERE, "rtl", "escape_mister.v")


def entity_ports(path):
    src = open(path).read()
    body = re.search(r"entity escape_core is(.*?)\bend escape_core",
                     src, re.S).group(1)
    ports = re.search(r"\bport\s*\((.*)\)\s*;\s*$", body.strip(), re.S).group(1)
    ports = "\n".join(re.sub(r"--.*$", "", ln) for ln in ports.splitlines())
    out = {}
    for decl in ports.split(";"):
        decl = decl.strip()
        m = re.match(r"([\w\s,]+?)\s*:\s*(in|out|inout)\b(.*)$", decl, re.S)
        if not m:
            continue
        for name in (n.strip() for n in m.group(1).split(",")):
            out[name.lower()] = (m.group(2), ":=" in m.group(3))
    return out


def instantiated_ports(path):
    src = open(path).read()
    inst = re.search(r"escape_core\s*#\(.*?\)\s*ecore\s*\((.*?)\n\);",
                     src, re.S).group(1)
    return set(x.lower() for x in re.findall(r"\.(\w+)\s*\(", inst))


def main():
    decls = entity_ports(VHDL)
    conn = instantiated_ports(VLOG)

    unknown = sorted(c for c in conn if c not in decls)
    missing = sorted(n for n, (d, dflt) in decls.items()
                     if d == "in" and not dflt and n not in conn)
    open_out = sorted(n for n, (d, _) in decls.items()
                      if d == "out" and n not in conn)

    print("escape_core: %d entity ports, %d connected, %d outputs left open"
          % (len(decls), len(conn), len(open_out)))

    ok = True
    if unknown:
        print("ERROR: connected but not on the entity: " + ", ".join(unknown))
        ok = False
    if missing:
        print("ERROR: mandatory inputs (no VHDL default) not connected: "
              + ", ".join(missing))
        ok = False
    if ok:
        print("Port list OK.")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
