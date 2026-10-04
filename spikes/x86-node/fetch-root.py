# fetch-root.py <alpine-ver> <outdir> [pkg ...]: unpack Alpine x86_64 packages
# and all their dependencies into outdir (default: nodejs)
import re, sys, os, subprocess, tarfile, io, urllib.request
ver, out = sys.argv[1], sys.argv[2]
base = f"https://dl-cdn.alpinelinux.org/alpine/{ver}"
pk, prov = {}, {}
for repo in ("main", "community"):
    raw = urllib.request.urlopen(f"{base}/{repo}/x86_64/APKINDEX.tar.gz").read()
    idx = tarfile.open(fileobj=io.BytesIO(raw)).extractfile("APKINDEX").read().decode()
    for blk in idx.split("\n\n"):
        d = {}
        for line in blk.split("\n"):
            if len(line) > 2 and line[1] == ":": d[line[0]] = line[2:]
        if "P" not in d or d["P"] in pk: continue
        d["repo"] = repo; pk[d["P"]] = d
        for tok in d.get("p", "").split(): prov.setdefault(tok.split("=")[0], []).append(d["P"])
        prov.setdefault(d["P"], []).append(d["P"])
prefer = {"icu-data": "icu-data-en"}
want, seen = sys.argv[3:] or ["nodejs"], []
while want:
    n = want.pop()
    if n in seen: continue
    seen.append(n)
    for dep in pk[n].get("D", "").split():
        if dep.startswith("!") or dep.startswith("/"): continue
        dep = re.split("[<>=~]", dep)[0]
        c = prov.get(dep)
        if not c: print("unresolved", dep); continue
        want.append(prefer[dep] if prefer.get(dep) in c else c[0])
os.makedirs(out, exist_ok=True)
for n in seen:
    p = pk[n]; url = f"{base}/{p['repo']}/x86_64/{n}-{p['V']}.apk"
    data = urllib.request.urlopen(url).read()
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        for m in t.getmembers():
            if m.name.startswith("."): continue
            t.extract(m, out, filter="tar") if hasattr(tarfile, "data_filter") else t.extract(m, out)
print(ver, "nodejs", pk["nodejs"]["V"], len(seen), "packages")
