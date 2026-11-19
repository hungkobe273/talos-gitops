#!/bin/bash
# Write a secret-free status file for the daily backup (19/11/2026), so read-only checkers (the Hermes
# skill talos-backup-check, user hermes) can see backup health without access to ~/talos-kvm (700).
# Runs as ExecStopPost of talos-etcd-backup.service (drop-in 50-status.conf): after every run, success,
# failure or skip. Can also be run by hand (no INVOCATION_ID): it rebuilds the file from the journal.
# Output: /var/lib/talos-backup/status.json (dir 755 ngochung, file 644). Contents: per run the time,
# result and the OK/ERROR/B2 lines of that run (paths shortened, company LAN IPs masked); per backup kind
# the newest file name, size, mtime and count; free space on /home. No file contents, no keys.
# Never fails the unit: any error is printed and the script exits 0.
OUT=${TALOS_BACKUP_STATUS:-/var/lib/talos-backup/status.json}
exec /usr/bin/python3 -I - "$OUT" <<'PY' || exit 0
import datetime as dt, glob, json, os, re, shutil, subprocess, sys, tempfile

out = sys.argv[1]
B = os.path.expanduser("~/talos-kvm")
UNIT = "talos-etcd-backup.service"
KEEP_RUNS = 10
LINE = re.compile(r"^\s*(OK:|ERROR|WARN|B2 uploaded|FAIL)")

def iso(ts):
    return dt.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")

def clean(s):
    s = s.replace(B + "/", "").replace(os.path.expanduser("~") + "/", "~/")
    return re.sub(r"\b192\.168\.\d{1,3}\.\d{1,3}\b", "<lan-ip>", s)[:220]

try:
    raw = subprocess.run(["journalctl", "-u", UNIT, "-o", "json", "--no-pager", "--since", "-14 days"],
                         capture_output=True, text=True, timeout=60).stdout
except Exception as e:
    raw = ""; print("journal unreadable:", e)

runs = {}
for l in raw.splitlines():
    try:
        d = json.loads(l)
    except ValueError:
        continue
    inv = d.get("_SYSTEMD_INVOCATION_ID") or d.get("INVOCATION_ID")
    msg = d.get("MESSAGE")
    if not inv or not isinstance(msg, str):
        continue
    ts = int(d.get("__REALTIME_TIMESTAMP", 0)) / 1e6
    r = runs.setdefault(inv, {"start": ts, "end": ts, "result": None, "lines": []})
    r["start"], r["end"] = min(r["start"], ts), max(r["end"], ts)
    if LINE.match(msg):
        r["lines"].append(clean(msg.strip()))
    low = msg.lower()
    if "skipped due to" in low or "condition check" in low:
        r["result"] = "skipped"
    elif "failed with result" in low or low.startswith("failed to start"):
        r["result"] = "failed"
    elif low.startswith("finished") and r["result"] is None:
        r["result"] = "success"

cur = os.environ.get("INVOCATION_ID")
if cur:  # ExecStopPost of this run: systemd tells the result before it logs "Finished"/"Failed"
    r = runs.setdefault(cur, {"start": dt.datetime.now().timestamp(), "end": dt.datetime.now().timestamp(),
                              "result": None, "lines": []})
    sr = os.environ.get("SERVICE_RESULT", "")
    r["result"] = {"success": "success", "exec-condition": "skipped"}.get(sr, "failed:" + sr if sr else None)

order = sorted(runs.items(), key=lambda kv: kv[1]["start"], reverse=True)[:KEEP_RUNS]
run_list = [{"start": iso(v["start"]), "end": iso(v["end"]), "result": v["result"] or "unknown",
             "lines": v["lines"][:12]} for _, v in order]

def kind(pattern):
    files = [f for f in glob.glob(os.path.join(B, pattern)) if os.path.isfile(f)]
    if not files:
        return {"count": 0}
    f = max(files, key=os.path.getmtime)
    st = os.stat(f)
    return {"count": len(files), "newest": os.path.basename(f), "bytes": st.st_size, "mtime": iso(st.st_mtime)}

local = {"etcd": kind("etcd-backups/*"), "keycloak": kind("keycloak-backups/keycloak-*.dump"),
         "vault": kind("vault-backups/vault-*.snap"), "offsite_bundle": kind("offsite/talos-offsite-*.tar.gz.gpg")}
ok = os.path.join(B, ".backup-last-ok")
du = shutil.disk_usage(os.path.expanduser("~"))
status = {"version": 1, "generated": iso(dt.datetime.now().timestamp()),
          "last_ok": iso(os.path.getmtime(ok)) if os.path.exists(ok) else None,
          "runs": run_list, "local": local,
          "disk_home": {"avail_bytes": du.free, "size_bytes": du.total}}

d = os.path.dirname(out)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".status.")
with os.fdopen(fd, "w") as f:
    json.dump(status, f, indent=1)
os.chmod(tmp, 0o644)
os.replace(tmp, out)
print("backup status written:", out, "runs", len(run_list), "last_ok", status["last_ok"])
PY
