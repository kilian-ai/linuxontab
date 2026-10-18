#!/usr/bin/env node
// Same workloads natively and in a headless guest; prints a table.
//
//   node headless/bench.mjs [--only name,name] [--runs 3]
//
// Guest timings are wall clock, taken on the host as marker lines arrive on
// the console (the lean guest has no `time` and no sub-second `date`), so
// each includes a few ms of console latency. Packages are installed before
// timing starts. Native runs use the host's own python3.11 / lua / jq / curl.
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import os from "node:os";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const { values: opt } = parseArgs({ options: { only: { type: "string" }, runs: { type: "string", default: "3" } } });
const RUNS = +opt.runs;
const TMP = os.tmpdir();

// name: [guest command, native command]
const WORKLOADS = {
  "python startup x5": ["for i in 1 2 3 4 5; do python3 -c pass; done", "for i in 1 2 3 4 5; do python3.11 -c pass; done"],
  "python cpu": ['python3 -c "sum(i*i for i in range(3000000))"', 'python3.11 -c "sum(i*i for i in range(3000000))"'],
  "python json": [
    `python3 -c "import json; d=[{'a':i,'b':str(i)} for i in range(200000)]; json.loads(json.dumps(d))"`,
    `python3.11 -c "import json; d=[{'a':i,'b':str(i)} for i in range(200000)]; json.loads(json.dumps(d))"`],
  "lua cpu": ['lua -e "local s=0 for i=1,30000000 do s=s+i%7 end"', 'lua -e "local s=0 for i=1,30000000 do s=s+i%7 end"'],
  // reduce, not [range(n)]: the guest's jq 1.7.1-r1 segfaults building arrays of 50k+ elements.
  "jq": ["jq -n 'reduce range(1000000) as $i (0; .+$i*2)'", "jq -n 'reduce range(1000000) as $i (0; .+$i*2)'"],
  "fork+exec x300": ["i=0; while [ $i -lt 300 ]; do /bin/true; i=$((i+1)); done", "i=0; while [ $i -lt 300 ]; do /usr/bin/true; i=$((i+1)); done"],
  "disk write 128 MiB": [
    "dd if=/dev/zero of=/root/bench.f bs=1048576 count=128 2>/dev/null; sync; rm /root/bench.f",
    `dd if=/dev/zero of=${TMP}/bench.f bs=1048576 count=128 2>/dev/null; sync; rm ${TMP}/bench.f`],
  "download 20 MB": [
    'curl -s -o /dev/null "https://speed.cloudflare.com/__down?bytes=20000000"',
    'curl -s -o /dev/null "https://speed.cloudflare.com/__down?bytes=20000000"'],
};
const names = opt.only ? opt.only.split(",") : Object.keys(WORKLOADS);

function native(cmd) {
  const t = performance.now();
  const r = spawnSync("/bin/sh", ["-c", cmd], { stdio: "ignore" });
  if (r.status !== 0) throw new Error(`native "${cmd}" exited ${r.status}`);
  return (performance.now() - t) / 1000;
}

const rssMiB = (pid) => { try { return +execFileSync("ps", ["-o", "rss=", "-p", String(pid)]).toString().trim() / 1024; } catch { return 0; } };

async function guest() {
  let script = "apk add python3 lua jq curl >/dev/null 2>&1\necho @@READY\n";
  for (const n of names) for (let r = 0; r < RUNS; r++)
    script += `echo "@@B ${r} ${n}"\n${WORKLOADS[n][0]} >/dev/null 2>&1\necho "@@E ${r} ${n} $?"\n`;
  // Run lot-run in-process-tree directly (with the shim) so the pid is the guest's.
  const child = spawn(process.execPath,
    ["--import", pathToFileURL(HERE + "shim.mjs").href, HERE + "lot-run.mjs", "--time", "-c", script],
    { stdio: ["ignore", "pipe", "pipe"] });
  const t0 = performance.now();
  const times = {}, starts = {};
  let bootS = 0, readyRss = 0, peakRss = 0, buf = "", err = "";
  const sampler = setInterval(() => { peakRss = Math.max(peakRss, rssMiB(child.pid)); }, 250);
  child.stderr.on("data", (d) => {
    err += d;
    if (!bootS && /boot complete/.test(err)) bootS = (performance.now() - t0) / 1000;
  });
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      const now = performance.now();
      if (line === "@@READY") { readyRss = rssMiB(child.pid); continue; }
      let m;
      if ((m = /^@@B (\d+) (.+)$/.exec(line))) starts[m[2] + "#" + m[1]] = now;
      else if ((m = /^@@E (\d+) (.+) (\d+)$/.exec(line))) {
        if (m[3] !== "0") throw new Error(`guest "${m[2]}" exited ${m[3]}`);
        (times[m[2]] ??= []).push((now - starts[m[2] + "#" + m[1]]) / 1000);
      }
    }
  });
  const code = await new Promise((res) => child.on("exit", res));
  clearInterval(sampler);
  if (code !== 0) throw new Error(`lot-run exited ${code}\n${err}`);
  return { times, bootS, readyRss, peakRss };
}

const med = (a) => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

process.stderr.write(`native: ${names.length} workloads x ${RUNS}\n`);
const nat = {};
for (const n of names) nat[n] = med(Array.from({ length: RUNS }, () => native(WORKLOADS[n][1])));
process.stderr.write("guest: booting lot-run\n");
const g = await guest();

const cpu = os.cpus()[0].model;
console.log(`\nHost: ${cpu}, ${os.cpus().length} cores, Node ${process.version}. Median of ${RUNS} runs.\n`);
console.log("| workload | native | guest | guest / native |");
console.log("|---|---:|---:|---:|");
for (const n of names) {
  const gm = med(g.times[n]);
  console.log(`| ${n} | ${nat[n].toFixed(2)} s | ${gm.toFixed(2)} s | ${(gm / nat[n]).toFixed(1)}x |`);
}
console.log(`\nBoot to first prompt: ${g.bootS.toFixed(1)} s. Guest process RSS: ${g.readyRss.toFixed(0)} MiB after installs, ${g.peakRss.toFixed(0)} MiB peak.`);
