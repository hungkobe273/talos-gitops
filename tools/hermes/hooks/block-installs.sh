#!/bin/sh
# Hermes pre_tool_call hook (18/11/2026): block package installs and privilege escalation.
# Installed root-owned at /usr/local/lib/hermes-hooks/block-installs.sh by setup-host2.sh, so the
# agent (user hermes) cannot edit it. Registered with fail_closed: if this script breaks, the tool
# call is blocked too.
# Why: 18/11 the model met "PyYAML missing" and ran pip install, apt-get, sudo apt-get, ensurepip on
# its own; approvals.mode manual did not ask for any of them (only `python3 -c` was asked).
# Protocol: JSON payload on stdin; exit 2 + reason on stderr = block; exit 0 = allow.
# Every block is appended to $HERMES_HOME/logs/policy-blocks.log (time, session, tool, rule).
exec /usr/bin/python3 -I -c '
import json, os, re, sys, time
try:
    p = json.load(sys.stdin)
except Exception:
    print("policy hook: unreadable payload", file=sys.stderr); sys.exit(2)
args = p.get("tool_input") or {}
text = " ".join(str(args.get(k, "")) for k in ("command", "code", "cmd", "input") if args.get(k))
if not text:
    sys.exit(0)
# A command word is at the start, or after a separator, a quote, a subshell or a path slash.
W = r"(?:^|[\s;&|(`$\x27\"/])"
E = r"(?=$|[\s;&|)`\x27\"])"
RULES = [
    ("privilege", W + r"(?:sudo|su|doas|pkexec|runuser)" + E),
    ("os-package", W + r"(?:apt|apt-get|aptitude|dpkg|snap|flatpak|brew)" + E),
    ("python-package", W + r"(?:pip|pip3|pip3\.\d+|pipx|easy_install|ensurepip|conda|mamba|micromamba|uv)" + E),
    ("python-package", r"-m\s+(?:pip|ensurepip)\b"),
    ("other-package", W + r"(?:npm|npx|pnpm|yarn|gem|cargo)" + E),
    ("other-package", W + r"go\s+(?:install|get)\b"),
    ("pipe-to-shell", r"(?:curl|wget)\b[^|]*\|\s*(?:sudo\s+)?(?:ba|z|da)?sh\b"),
]
for rule, rx in RULES:
    if re.search(rx, text):
        home = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
        try:
            os.makedirs(os.path.join(home, "logs"), exist_ok=True)
            with open(os.path.join(home, "logs", "policy-blocks.log"), "a") as f:
                f.write("%s session=%s tool=%s rule=%s\n" % (time.strftime("%F %T"),
                        p.get("session_id"), p.get("tool_name"), rule))
        except OSError:
            pass
        print("BLOCKED by host policy (%s): this agent may not install packages or use sudo/su. "
              "Do not retry another way. Tell the user which tool or module is missing and stop."
              % rule, file=sys.stderr)
        sys.exit(2)
sys.exit(0)
'
