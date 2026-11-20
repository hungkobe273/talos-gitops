#!/bin/sh
# Hermes pre_tool_call hook (18/11/2026, rewritten 20/11): block package installs, privilege
# escalation, running self-written scripts, changes to Hermes' own config and credential files.
# Installed root-owned at /usr/local/lib/hermes-hooks/block-installs.sh by setup-host2.sh from the
# root-owned clone /opt/talos-gitops, so the agent (user hermes) cannot edit it. Registered with
# fail_closed: if this script breaks, the tool call is blocked too.
# Why: 18/11 the model met "PyYAML missing" and ran pip install, apt-get, sudo apt-get, ensurepip on
# its own; approvals.mode manual did not ask for any of them. 20/11 an independent review found ways
# around the first version (python3 -mpip, \pip, p""ip, curl | /bin/bash, bash <(curl ..), a script
# written with the file tool and then run, `hermes config set hooks`).
# This is text matching, so it is best effort: the real fence is that user hermes has no sudo, a
# read-only ServiceAccount, and root-owned skills, hook and config.
# Tools: terminal/process/execute_code (command text), read_file/write_file/patch/search_files (path).
# Protocol: JSON payload on stdin; exit 2 + reason on stderr = block; exit 0 = allow.
# Every block is appended to $HERMES_HOME/logs/policy-blocks.log (time, session, tool, rule).
exec /usr/bin/python3 -I -c '
import json, os, re, sys, time

def block(rule, p):
    home = os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")
    try:
        os.makedirs(os.path.join(home, "logs"), exist_ok=True)
        with open(os.path.join(home, "logs", "policy-blocks.log"), "a") as f:
            f.write("%s session=%s tool=%s rule=%s\n" % (time.strftime("%F %T"),
                    p.get("session_id") if isinstance(p, dict) else None,
                    p.get("tool_name") if isinstance(p, dict) else None, rule))
    except OSError:
        pass
    print("BLOCKED by host policy (rule %s): this agent may not install packages, use sudo/su, run "
          "scripts it wrote, change Hermes config or touch credential files. The text matched that "
          "rule; if the command was none of those, rephrase it without that word. Do not retry another "
          "way; tell the user what you needed and stop." % rule, file=sys.stderr)
    sys.exit(2)

# A command word is at the start, or after a separator, a quote, a subshell, a brace or a path slash.
W = r"(?:^|[\s;&|(`$\x27\"/{,\\])"
E = r"(?=$|[\s;&|)`\x27\"},])"
CMD_RULES = [
    ("privilege", W + r"(?:sudo|su|doas|pkexec|runuser|chattr|setfacl)" + E),
    ("os-package", W + r"(?:apt|apt-get|aptitude|dpkg|snap|flatpak|brew)" + E),
    ("python-package", W + r"(?:pip|pip3|pip3\.\d+|pipx|easy_install|ensurepip|conda|mamba|micromamba|uv|virtualenv)" + E),
    ("python-package", r"-m\s*(?:pip|ensurepip|venv|virtualenv)\b"),
    ("python-package", r"\brunpy\b|run_module"),
    ("other-package", W + r"(?:npm|npx|pnpm|yarn|gem|cargo)" + E),
    ("other-package", W + r"go\s+(?:install|get)\b"),
    ("pipe-to-shell", r"(?:curl|wget)\b[^\n]*\|\s*(?:\S*/)?(?:(?:ba|z|da|k)?sh|python[\d.]*|perl)\b"),
    ("pipe-to-shell", r"<\(\s*(?:curl|wget)\b|\$\(\s*(?:curl|wget)\b|`\s*(?:curl|wget)\b"),
    ("pipe-to-shell", r"base64\s+(?:-d|--decode)\b[^\n]*\|\s*(?:\S*/)?(?:(?:ba|z|da|k)?sh|python[\d.]*)\b"),
    ("indirection", W + r"eval" + E),
    # Running a script the agent wrote (file tool, heredoc, echo > file). Skills are run as
    # `bash scripts/...` from their directory under /opt/talos-gitops, which this does not match.
    ("own-script", W + r"(?:(?:ba|z|da|k)?sh|python[\d.]*|perl|ruby|node)\s+(?:-\S+\s+)*(?:/tmp/|/var/tmp/|/dev/shm/|~|/home/|\.\.?/|\$HOME)"),
    ("own-script", r"(?:^|[;&|(]\s*)\.\.?/\S"),
    ("own-script", r"\bchmod\s+(?:-\S+\s+)*(?:[ugoa]*\+[rw]*x|[0-7]*[1357][0-7]{0,2}\b)"),
    ("own-script", r"(?:^|[;&|(]\s*)(?:source|\.)\s+(?:/tmp/|/var/tmp/|~|/home/|\$HOME)"),
    ("hermes-config", W + r"hermes\s+(?:config|hooks|tools|setup|update|plugins|auth|login|gateway|skills\s+(?:install|uninstall|tap))\b"),
]
# Paths no tool may touch, in a command or in a file tool path.
PATH_RULES = [
    ("credential-file", r"\.hermes/(?:\.env|auth\.json)|\.kube/config|talos-kvm/|\.ssh/|\.git-credentials"),
    ("hermes-config", r"\.hermes/(?:config\.ya?ml|hooks)|/usr/local/lib/hermes-hooks"),
]
WRITE_TOOLS = ("write_file", "patch")
SKILLS = r"/opt/talos-gitops/"

def variants(t):
    """The text as given, and with shell quoting removed (p\"\"ip, \\pip, {pip,install}, $\x27\\x70ip\x27)."""
    n = re.sub(r"\$\x27((?:\\x[0-9a-fA-F]{2}|[^\x27])*)\x27",
               lambda m: re.sub(r"\\x([0-9a-fA-F]{2})", lambda h: chr(int(h.group(1), 16)), m.group(1)), t)
    n = n.replace("\\", "").replace("\"", "").replace("\x27", "")
    n = re.sub(r"[{},]", " ", n)
    return {t, n, t.lower(), n.lower()}

try:
    p = json.load(sys.stdin)
    if not isinstance(p, dict):
        block("unreadable-payload", p)
    tool = str(p.get("tool_name") or "")
    args = p.get("tool_input")
    if not isinstance(args, dict):
        args = {"command": args} if args else {}
    cmd = " ".join(str(args.get(k)) for k in ("command", "code", "cmd", "input", "script") if args.get(k))
    paths = " ".join(str(args.get(k)) for k in ("path", "file_path", "filename", "patch") if args.get(k))
    if cmd:
        for t in variants(cmd):
            for rule, rx in CMD_RULES + PATH_RULES:
                if re.search(rx, t):
                    block(rule, p)
    if paths:
        for t in variants(paths):
            for rule, rx in PATH_RULES:
                if re.search(rx, t):
                    block(rule, p)
            if tool in WRITE_TOOLS and re.search(SKILLS, t):
                block("skills", p)
except SystemExit:
    raise
except Exception:
    block("hook-error", {})
sys.exit(0)
'
