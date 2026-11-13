"""Rebuild src/ from script sources that an execute_luau call printed to the Studio log.
Usage: python3 tools/export_from_studio_log.py <RUN_ID> src
"""
import sys, re, os, glob
run = sys.argv[1]; out = sys.argv[2]
# several Studio windows may be open: use whichever recent log contains this run id
logs = sorted(glob.glob(os.path.expanduser("~/Library/Logs/Roblox/*_Studio_*_last.log")), key=os.path.getmtime, reverse=True)[:6]
log = next((l for l in logs if ("MDXPATH|%s|" % run) in open(l, errors="replace").read()), None)
assert log, "run id %s not found in recent Studio logs" % run
paths, chunks, ends = {}, {}, {}
for line in open(log, errors="replace"):
    m = re.search(r"MDXPATH\|%s\|(\d+)\|([^|]+)\|(\w+)\|(\d+)" % run, line)
    if m: paths[int(m[1])] = (m[2], m[3], int(m[4])); continue
    m = re.search(r"MDX\|%s\|(\d+)\|(\d+)\|([0-9a-f]+)" % run, line)
    if m: chunks.setdefault(int(m[1]), {})[int(m[2])] = m[3]; continue
    m = re.search(r"MDXEND\|%s\|(\d+)\|(\d+)" % run, line)
    if m: ends[int(m[1])] = int(m[2])
ext = {"Script": ".server.luau", "LocalScript": ".client.luau", "ModuleScript": ".luau"}
for i, (p, cls, kids) in sorted(paths.items()):
    c = chunks.get(i, {})
    assert len(c) == ends[i], (p, len(c), ends[i])
    src = bytes.fromhex("".join(c[k] for k in sorted(c))).decode("utf-8")
    # a script with children becomes a folder with init file (Rojo convention)
    if kids > 0:
        f = os.path.join(out, p, "init" + ext[cls])
    else:
        f = os.path.join(out, p + ext[cls])
    os.makedirs(os.path.dirname(f), exist_ok=True)
    open(f, "w").write(src)
    print(f, len(src.splitlines()))
