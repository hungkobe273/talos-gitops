#!/usr/bin/env python3
"""Daily backup health of talos-kvm for an LLM agent (or a human). Read-only.

Reads /var/lib/talos-backup/status.json, written after every run of talos-etcd-backup.service by
host2/bin/talos-backup-status.sh (no secrets: names, sizes, times, OK/ERROR lines), and the timer.
Checks: age of the last fully successful run (etcd + Keycloak + Vault + bundle + B2 + GCS), the
latest run's result, all six parts present, sealed-secrets keys in the bundle, size jumps against
earlier runs, local files refreshed, free disk. At most ~25 lines.
Exit: 0 OK, 1 something to look at, 2 status file missing or unreadable.
"""
import datetime as dt
import json
import os
import re
import statistics
import subprocess
import sys

STATUS = os.environ.get("TALOS_BACKUP_STATUS", "/var/lib/talos-backup/status.json")
PARTS = [("etcd", r"^OK: snapshot "), ("keycloak", r"^OK: pg_dump keycloak"), ("vault", r"^OK: vault snapshot"),
         ("bundle", r"^OK: offsite "), ("B2", r"^B2 uploaded "), ("GCS", r"^OK: GCS uploaded ")]

now = dt.datetime.now().astimezone()


def t(s):
    return dt.datetime.fromisoformat(s) if s else None


def ago(x):
    h = (now - x).total_seconds() / 3600
    return "%dm ago" % (h * 60) if h < 1 else "%.0fh ago" % h


def hb(n):
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or u == "TiB":
            return ("%.0f %s" if u in ("B", "GiB", "TiB") else "%.1f %s") % (n, u)
        n /= 1024.0


def allowed_hours(last):
    # The cluster is off nights and weekends: allow 26 h plus 24 h per Saturday/Sunday since the last backup.
    days, d = 0, last.date()
    while d < now.date():
        d += dt.timedelta(days=1)
        days += d.weekday() >= 5
    return 26 + 24 * days


try:
    s = json.load(open(STATUS))
except FileNotFoundError:
    print("SETUP: %s not found. The status writer (host2/bin/talos-backup-status.sh, drop-in 50-status.conf) "
          "is not installed. Tell the human; do not look for backups elsewhere." % STATUS)
    sys.exit(2)
except (OSError, ValueError) as e:
    print("SETUP: cannot read %s (%s). Tell the human." % (STATUS, e.__class__.__name__))
    sys.exit(2)

items, lines = [], []
runs = s.get("runs") or []
last_ok = t(s.get("last_ok"))
gen = t(s.get("generated"))

if last_ok is None:
    items.append("no fully successful backup recorded (.backup-last-ok missing)")
else:
    lim = allowed_hours(last_ok)
    age_h = (now - last_ok).total_seconds() / 3600
    lines.append("LAST OK: %s (%s, allowed %dh)" % (last_ok.strftime("%a %d/%m %H:%M"), ago(last_ok), lim))
    if age_h > lim:
        items.append("last successful backup is %.0fh old (> %dh)" % (age_h, lim))
    if gen and gen < last_ok - dt.timedelta(minutes=1):
        items.append("status file (%s) is older than the last backup: status writer did not run" % gen.strftime("%d/%m %H:%M"))

if runs:
    r0 = runs[0]
    lines.append("LAST RUN: %s %s" % (t(r0["start"]).strftime("%a %d/%m %H:%M"), r0["result"]))
    if not r0["result"].startswith(("success", "skipped")):
        items.append("latest run %s at %s" % (r0["result"], t(r0["start"]).strftime("%d/%m %H:%M")))
        for l in [l for l in r0["lines"] if not l.startswith("OK:") and not l.startswith("B2 ")][:3]:
            lines.append("  " + l)
    if r0["result"] == "skipped":
        lines.append("  (skipped = cp1 was not running at timer time, normal after talos-cluster-stop.sh)")

succ = [r for r in runs if r["result"] == "success"]
if succ:
    r = succ[0]
    got, parts = {}, []
    for name, rx in PARTS:
        hit = next((l for l in r["lines"] if re.search(rx, l)), None)
        got[name] = hit
        if hit is None:
            items.append("last successful run has no %s line" % name)
    m = re.search(r"\((\d+) bytes", got["etcd"] or "")
    etcd_b = int(m.group(1)) if m else None
    m = re.search(r"(\d+) bang co du lieu", got["keycloak"] or "")
    kc_tables = int(m.group(1)) if m else None
    m = re.search(r" (\d+) files, (\d+) sealed-secrets key", got["bundle"] or "")
    nfiles, nkeys = (int(m.group(1)), int(m.group(2))) if m else (None, None)
    m = re.search(r" (\d+) bytes", got["B2"] or "")
    bundle_b = int(m.group(1)) if m else None
    if nkeys is not None and nkeys < 1:
        items.append("bundle has no sealed-secrets key: it cannot restore SealedSecrets")
    lines.append("PARTS (%s): etcd %s, keycloak %s, vault %s, bundle %s, B2 %s, GCS %s" % (
        t(r["start"]).strftime("%d/%m %H:%M"),
        hb(etcd_b) if etcd_b else "?",
        "%d tables" % kc_tables if kc_tables else ("ok" if got["keycloak"] else "missing"),
        "ok" if got["vault"] else "missing",
        "%s, %s files, %s sealed-secrets keys" % (hb(bundle_b) if bundle_b else "?", nfiles, nkeys) if got["bundle"] else "missing",
        "ok" if got["B2"] else "missing", "ok" if got["GCS"] else "missing"))

    def sizes(rx):
        out = []
        for x in succ[1:6]:
            l = next((l for l in x["lines"] if re.search(rx, l)), "")
            m = re.search(r"\((\d+) bytes|uploaded \S+ (\d+) bytes", l)
            if m:
                out.append(int(m.group(1) or m.group(2)))
        return out
    for label, cur, prev in (("etcd snapshot", etcd_b, sizes(PARTS[0][1])), ("bundle", bundle_b, sizes(PARTS[4][1]))):
        if cur and len(prev) >= 2:
            med = statistics.median(prev)
            if cur < 0.6 * med or cur > 2.0 * med:
                items.append("%s size %s vs usual %s (median of %d earlier runs)" % (label, hb(cur), hb(med), len(prev)))
    if nfiles and len(succ) > 1:
        m = re.search(r" (\d+) files,", next((l for l in succ[1]["lines"] if l.startswith("OK: offsite")), ""))
        if m and nfiles < int(m.group(1)):
            items.append("bundle has %d files, previous run had %s" % (nfiles, m.group(1)))

fails = [x for x in runs[1:] if x["result"].startswith("failed")]
if fails:
    lines.append("EARLIER FAILURES (recovered): " + ", ".join(t(x["start"]).strftime("%d/%m %H:%M") for x in fails[:3]))

loc = s.get("local") or {}
lines.append("LOCAL KEPT: " + ", ".join("%s %s" % (k, v.get("count", 0)) for k, v in loc.items()))
if last_ok:
    for k, v in loc.items():
        mt = t(v.get("mtime"))
        if mt is None:
            items.append("no local %s file" % k)
        elif mt < last_ok - dt.timedelta(minutes=30):
            items.append("newest local %s file (%s) is older than the last backup" % (k, mt.strftime("%d/%m %H:%M")))

dk = s.get("disk_home") or {}
if dk.get("size_bytes"):
    pct = 100.0 * dk["avail_bytes"] / dk["size_bytes"]
    lines.append("DISK /home: %s free (%.0f%%)" % (hb(dk["avail_bytes"]), pct))
    if pct < 10:
        items.append("/home has only %.0f%% free" % pct)

try:
    nxt = subprocess.run(["systemctl", "show", "talos-etcd-backup.timer", "-p", "NextElapseUSecRealtime", "--value"],
                         capture_output=True, text=True, timeout=10).stdout.strip()
except Exception:
    nxt = ""
lines.append("NEXT TIMER: %s (status file %s)" % (nxt or "unknown", gen.strftime("%d/%m %H:%M") if gen else "?"))

print(("CHECK %d item(s)" % len(items)) if items else "OK")
for i in items:
    print("- " + i)
print("\n".join(lines))
sys.exit(1 if items else 0)
