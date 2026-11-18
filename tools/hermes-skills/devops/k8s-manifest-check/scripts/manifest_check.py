#!/usr/bin/env python3
"""Check Kubernetes YAML before it goes to Git, for an LLM agent (or a human).

Usage: manifest_check.py <file.yaml | -> [namespace]
  -            read YAML from stdin (pasted manifest)
  namespace    used when a document has no metadata.namespace (default: "default")

Read-only. Talks to the cluster only with GET: the OpenAPI v3 schema (/openapi/v3/...) and
`kubectl get namespace` for the Pod Security label. Kyverno policies are read from the repo
(platform/kyverno/manifests), not from the API (the hermes-readonly SA cannot list them).

Checks per document:
  SCHEMA  unknown fields, missing required fields, wrong types, values outside an enum,
          apiVersion/kind not served by this cluster (same schema the API server uses).
  PSA     Pod Security Standards of the target namespace (baseline / restricted), as the
          API server would enforce them at admission.
  KYVERNO ImageValidatingPolicy of this repo that matches the namespace and image.
  BEST    image tag latest/missing, requests/limits, probes, readOnlyRootFilesystem.
  HINT    known traps (official nginx image as non-root, runAsNonRoot without runAsUser).

Values are never printed except enum mismatches, image names and namespace names: the output
goes to a cloud LLM and a manifest may hold secrets. Secret documents are not inspected.
Exit: 0 no ERROR (WARN allowed), 1 at least one ERROR, 2 usage / file / cluster unreadable.
"""
import fnmatch
import glob
import json
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("SETUP: PyYAML missing for %s. Stop and tell the human; do not install packages "
          "(the script must run with /usr/bin/python3, Ubuntu package python3-yaml)" % sys.executable)
    sys.exit(2)

MAX_LINES_PER_DOC = 18
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), *[".."] * 5))

POD_SPEC_PATHS = {
    "Pod": ["spec"],
    "Deployment": ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "DaemonSet": ["spec", "template", "spec"],
    "ReplicaSet": ["spec", "template", "spec"],
    "Job": ["spec", "template", "spec"],
    "CronJob": ["spec", "jobTemplate", "spec", "template", "spec"],
    "Rollout": ["spec", "template", "spec"],
}
BATCH_KINDS = {"Job", "CronJob"}
CLUSTER_SCOPED = {"Namespace", "Node", "PersistentVolume", "StorageClass", "IngressClass", "PriorityClass",
                  "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition", "ClusterIssuer",
                  "ClusterSecretStore", "ImageValidatingPolicy", "ValidatingPolicy", "ClusterPolicy",
                  "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding",
                  "ValidatingWebhookConfiguration", "MutatingWebhookConfiguration", "AppProject"}
BASELINE_CAPS = {"AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "MKNOD",
                 "NET_BIND_SERVICE", "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"}
RESTRICTED_VOLUMES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral",
                      "persistentVolumeClaim", "projected", "secret", "image"}


def kubectl(*args):
    try:
        r = subprocess.run(["kubectl", "--request-timeout=20s", *args],
                           capture_output=True, text=True, timeout=40)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


# ---------------------------------------------------------------- schema (OpenAPI v3)
_openapi_cache = {}


def schema_for(api_version, kind):
    """Return (schemas, root schema) or (None, reason)."""
    path = "api/v1" if api_version == "v1" else "apis/" + api_version
    if path not in _openapi_cache:
        raw = kubectl("get", "--raw", "/openapi/v3/" + path)
        _openapi_cache[path] = json.loads(raw)["components"]["schemas"] if raw else None
    schemas = _openapi_cache[path]
    if schemas is None:
        return None, "apiVersion %s is not served by this cluster (CRD missing or typo)" % api_version
    group, _, version = api_version.rpartition("/")
    for s in schemas.values():
        for gvk in s.get("x-kubernetes-group-version-kind", []):
            if gvk.get("kind") == kind and gvk.get("group", "") == group and gvk.get("version") == version:
                return schemas, s
    return None, "kind %s does not exist in %s" % (kind, api_version)


def resolve(schemas, s):
    for _ in range(10):
        if "$ref" in s:
            s = schemas.get(s["$ref"].split("/")[-1], {})
        elif "allOf" in s and len(s["allOf"]) == 1 and not s.get("properties"):
            s = s["allOf"][0]
        else:
            return s
    return s


def type_name(v):
    return {bool: "boolean", int: "integer", float: "number", str: "string",
            list: "array", dict: "object"}.get(type(v), "null")


def validate(schemas, node, s, path, out):
    s = resolve(schemas, s)
    if not s or s.get("x-kubernetes-preserve-unknown-fields"):
        return
    if node is None:
        return  # explicit null is accepted by the API server for optional fields
    if s.get("x-kubernetes-int-or-string"):
        if not isinstance(node, (int, str)) or isinstance(node, bool):
            out.append("%s: expected integer or string, got %s" % (path, type_name(node)))
        return
    t = s.get("type")
    if t == "object" or (t is None and "properties" in s):
        if not isinstance(node, dict):
            out.append("%s: expected object, got %s" % (path, type_name(node))); return
        props = s.get("properties", {})
        extra = s.get("additionalProperties")
        for k, v in node.items():
            p = "%s.%s" % (path, k) if path else str(k)
            if k in props:
                validate(schemas, v, props[k], p, out)
            elif isinstance(extra, dict):
                validate(schemas, v, extra, p, out)
            elif extra is True or (not props and extra is None):
                pass
            else:
                out.append("%s: unknown field" % p)
        for r in s.get("required", []):
            if r not in node:
                out.append("%s: missing required field" % ("%s.%s" % (path, r) if path else r))
    elif t == "array":
        if not isinstance(node, list):
            out.append("%s: expected array, got %s" % (path, type_name(node))); return
        for i, v in enumerate(node):
            validate(schemas, v, s.get("items", {}), "%s[%d]" % (path, i), out)
    elif t in ("string", "integer", "number", "boolean"):
        ok = {"string": isinstance(node, str),
              "integer": isinstance(node, int) and not isinstance(node, bool),
              "number": isinstance(node, (int, float)) and not isinstance(node, bool),
              "boolean": isinstance(node, bool)}[t]
        if not ok:
            out.append("%s: expected %s, got %s" % (path, t, type_name(node)))
        elif "enum" in s and node not in s["enum"]:
            out.append('%s: "%s" is not one of %s' % (path, str(node)[:40], ", ".join(map(str, s["enum"]))))


# ---------------------------------------------------------------- pod spec helpers
def dig(d, keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def containers(spec):
    for field in ("initContainers", "containers", "ephemeralContainers"):
        for c in spec.get(field) or []:
            if isinstance(c, dict):
                yield field, c


def eff(pod_sc, c, key):
    """Container securityContext value, falling back to the pod-level one."""
    v = (c.get("securityContext") or {}).get(key)
    return v if v is not None else (pod_sc or {}).get(key)


def image_parts(image):
    """-> (repository without registry for docker hub library images, tag or '', digest?)"""
    digest = "@" in image
    name = image.split("@")[0]
    last = name.rsplit("/", 1)[-1]
    tag = last.split(":", 1)[1] if ":" in last else ""
    repo = name[: len(name) - len(tag) - 1] if tag else name
    for prefix in ("docker.io/library/", "docker.io/", "index.docker.io/library/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix):]
    return repo, tag, digest


def psa_checks(spec, level):
    errs = []
    if level not in ("baseline", "restricted"):
        return errs
    pod_sc = spec.get("securityContext") or {}
    for f in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(f):
            errs.append("%s: true is not allowed" % f)
    for v in spec.get("volumes") or []:
        if not isinstance(v, dict):
            continue
        kinds = [k for k in v if k != "name"]
        if "hostPath" in kinds:
            errs.append("volume %s: hostPath is not allowed" % v.get("name"))
        elif level == "restricted" and kinds and kinds[0] not in RESTRICTED_VOLUMES:
            errs.append("volume %s: type %s is not allowed (restricted)" % (v.get("name"), kinds[0]))
    if (pod_sc.get("seccompProfile") or {}).get("type") == "Unconfined":
        errs.append("pod seccompProfile Unconfined is not allowed")
    for _, c in containers(spec):
        n = c.get("name", "?")
        sc = c.get("securityContext") or {}
        if sc.get("privileged"):
            errs.append("container %s: privileged: true is not allowed" % n)
        for p in c.get("ports") or []:
            if isinstance(p, dict) and p.get("hostPort"):
                errs.append("container %s: hostPort is not allowed" % n)
        caps = sc.get("capabilities") or {}
        add = set(caps.get("add") or [])
        bad = add - BASELINE_CAPS if level == "baseline" else add - {"NET_BIND_SERVICE"}
        if bad:
            errs.append("container %s: capabilities.add %s not allowed" % (n, ",".join(sorted(bad))))
        if (sc.get("seccompProfile") or {}).get("type") == "Unconfined":
            errs.append("container %s: seccompProfile Unconfined is not allowed" % n)
        if level != "restricted":
            continue
        if sc.get("allowPrivilegeEscalation") is not False:
            errs.append("container %s: securityContext.allowPrivilegeEscalation must be false" % n)
        if eff(pod_sc, c, "runAsNonRoot") is not True:
            errs.append("container %s: runAsNonRoot must be true (pod or container securityContext)" % n)
        if eff(pod_sc, c, "runAsUser") == 0:
            errs.append("container %s: runAsUser 0 is not allowed" % n)
        sp = (eff(pod_sc, c, "seccompProfile") or {}).get("type")
        if sp not in ("RuntimeDefault", "Localhost"):
            errs.append("container %s: seccompProfile.type must be RuntimeDefault (pod or container)" % n)
        if "ALL" not in (caps.get("drop") or []):
            errs.append("container %s: capabilities.drop must include ALL" % n)
    return errs


def kustomize_images(src):
    """Image names whose tag a kustomization.yaml next to the file sets (images[].newTag/digest)."""
    if src == "-":
        return set()
    for fn in ("kustomization.yaml", "kustomization.yml", "Kustomization"):
        try:
            k = yaml.safe_load(open(os.path.join(os.path.dirname(os.path.abspath(src)), fn), encoding="utf-8"))
        except (OSError, yaml.YAMLError):
            continue
        return {i.get("name") for i in (k or {}).get("images") or []
                if isinstance(i, dict) and (i.get("newTag") or i.get("digest"))}
    return set()


def best_and_hints(kind, spec, kust_images=frozenset()):
    warns, hints = [], []
    pod_sc = spec.get("securityContext") or {}
    for field, c in containers(spec):
        if field == "ephemeralContainers":
            continue
        n = c.get("name", "?")
        image = str(c.get("image", ""))
        repo, tag, digest = image_parts(image)
        if not digest and tag in ("", "latest") and image.split("@")[0].rsplit(":", 1)[0] in kust_images:
            hints.append("container %s: image %s has no tag here; kustomization.yaml sets it "
                         "(images newTag), fine" % (n, image))
        elif not digest and tag in ("", "latest"):
            warns.append("container %s: image %s has tag %s; pin a version (or digest), Argo CD cannot "
                         "see a new :latest" % (n, image, tag or "(none = latest)"))
        res = c.get("resources") or {}
        if not (res.get("requests") or {}).get("memory") or not (res.get("requests") or {}).get("cpu"):
            warns.append("container %s: resources.requests cpu/memory missing (worker RAM is tight)" % n)
        if not (res.get("limits") or {}).get("memory"):
            warns.append("container %s: resources.limits.memory missing" % n)
        if field == "containers" and kind not in BATCH_KINDS:
            if not c.get("readinessProbe"):
                warns.append("container %s: no readinessProbe" % n)
            if not c.get("livenessProbe"):
                warns.append("container %s: no livenessProbe" % n)
        if (c.get("securityContext") or {}).get("readOnlyRootFilesystem") is not True:
            warns.append("container %s: readOnlyRootFilesystem is not true" % n)
        non_root = eff(pod_sc, c, "runAsNonRoot") is True
        uid = eff(pod_sc, c, "runAsUser")
        if repo == "nginx" and (non_root or (isinstance(uid, int) and uid != 0)):
            hints.append("container %s: the official nginx image runs as root (master process, port 80, "
                         "writes /var/cache/nginx and /var/run/nginx.pid). As non-root it fails: without "
                         "runAsUser kubelet refuses it (CreateContainerConfigError: image will run as root), "
                         "with runAsUser it crashes on permission denied. Use nginxinc/nginx-unprivileged "
                         "(UID 101, listens on 8080) and change containerPort/Service targetPort to 8080" % n)
        elif non_root and uid is None and repo != "nginxinc/nginx-unprivileged":
            hints.append("container %s: runAsNonRoot without runAsUser only works if the image USER is a "
                         "numeric non-root UID; otherwise CreateContainerConfigError. Set runAsUser "
                         "(and runAsGroup) explicitly" % n)
        if repo == "nginxinc/nginx-unprivileged" and \
                (c.get("securityContext") or {}).get("readOnlyRootFilesystem") is True:
            mounts = {m.get("mountPath") for m in c.get("volumeMounts") or [] if isinstance(m, dict)}
            if "/tmp" not in mounts:
                hints.append("container %s: nginx-unprivileged with readOnlyRootFilesystem needs an emptyDir "
                             "mounted at /tmp (pid file and temp paths)" % n)
    return warns, hints


# ---------------------------------------------------------------- Kyverno (from repo)
def load_image_policies():
    pols = []
    for f in sorted(glob.glob(os.path.join(REPO, "platform", "kyverno", "manifests", "*.yaml"))):
        try:
            docs = list(yaml.safe_load_all(open(f, encoding="utf-8")))
        except (OSError, yaml.YAMLError):
            continue
        for d in docs:
            if not isinstance(d, dict) or d.get("kind") != "ImageValidatingPolicy":
                continue
            spec = d.get("spec") or {}
            ns = dig(spec, ["matchConstraints", "namespaceSelector", "matchLabels",
                            "kubernetes.io/metadata.name"])
            globs = [r.get("glob") for r in spec.get("matchImageReferences") or [] if r.get("glob")]
            msgs = [v.get("message") for v in spec.get("validations") or [] if v.get("message")]
            pols.append({"name": dig(d, ["metadata", "name"]), "ns": ns, "globs": globs,
                         "msg": msgs[0] if msgs else "", "file": os.path.relpath(f, REPO)})
    return pols


# ---------------------------------------------------------------- main
def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print("usage: manifest-check.sh <file.yaml | -> [namespace]"); return 2
    src, default_ns = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "default")
    try:
        text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    except OSError as e:
        print("FILE: cannot read %s (%s)" % (src, e.strerror)); return 2
    try:
        docs = [d for d in yaml.safe_load_all(text) if d is not None]
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        where = " at line %d column %d" % (mark.line + 1, mark.column + 1) if mark else ""
        print("RESULT: FAIL (YAML does not parse%s: %s)" % (where, getattr(e, "problem", "") or "syntax error"))
        return 1
    expanded = []
    for d in docs:
        if isinstance(d, dict) and d.get("kind") == "List":
            expanded += [i for i in d.get("items") or [] if isinstance(i, dict)]
        else:
            expanded.append(d)
    if not expanded:
        print("RESULT: FAIL (no YAML documents)"); return 1
    if not any(isinstance(d, dict) and (d.get("apiVersion") or d.get("kind")) for d in expanded):
        print("RESULT: SKIP (no apiVersion/kind: not a Kubernetes manifest. A Helm values.yaml is checked "
              "by rendering the chart first, which this script does not do)")
        return 2
    if kubectl("get", "--raw", "/readyz") is None:
        print("API: UNREACHABLE (cannot load the cluster schema)"); return 2

    ns_labels, policies, kust = {}, load_image_policies(), kustomize_images(src)
    lines, n_err, n_warn = [], 0, 0
    for i, d in enumerate(expanded, 1):
        if not isinstance(d, dict):
            lines.append("DOC %d: not a mapping (got %s)" % (i, type_name(d))); n_err += 1; continue
        api, kind = d.get("apiVersion"), d.get("kind")
        meta = d.get("metadata") if isinstance(d.get("metadata"), dict) else {}
        name = meta.get("name") or meta.get("generateName") or "?"
        ns = meta.get("namespace") or default_ns
        head = "DOC %d %s %s" % (i, kind or "?", name if kind in CLUSTER_SCOPED else ns + "/" + name)
        out_err, out_warn, out_hint, notes = [], [], [], []
        if not api or not kind:
            out_err.append("SCHEMA apiVersion and kind are required")
        elif str(api).startswith("kustomize.config.k8s.io/"):
            notes.append("NOTE kustomize build file, not sent to the cluster; not checked")
        elif kind == "Secret":
            notes.append("NOTE Secret: values not inspected. Do not commit a plain Secret to talos-gitops "
                         "(public repo); use a SealedSecret or an ExternalSecret from Vault")
        else:
            schemas, root = schema_for(api, kind)
            if schemas is None:
                out_err.append("SCHEMA " + root)
            else:
                errs = []
                validate(schemas, {k: v for k, v in d.items() if k != "status"}, root, "", errs)
                out_err += ["SCHEMA " + e for e in errs]
        spec = dig(d, POD_SPEC_PATHS.get(kind, ["__none__"]))
        if kind == "Rollout" and isinstance(d.get("spec"), dict) and d["spec"].get("workloadRef"):
            notes.append("NOTE Rollout uses workloadRef: pod template is in the referenced Deployment")
        if isinstance(spec, dict):
            if ns not in ns_labels:
                raw = kubectl("get", "namespace", ns, "-o", "json")
                ns_labels[ns] = json.loads(raw)["metadata"].get("labels", {}) if raw else None
            labels = ns_labels[ns]
            if labels is None:
                out_warn.append("NS namespace %s does not exist in the cluster (or is not readable); "
                                "Pod Security level unknown, checked as restricted" % ns)
                level = "restricted"
            else:
                level = labels.get("pod-security.kubernetes.io/enforce", "privileged")
            head += "  (ns Pod Security: %s)" % level
            out_err += ["PSA %s %s" % (level, e) for e in psa_checks(spec, level)]
            w, h = best_and_hints(kind, spec, kust)
            out_warn += ["BEST " + x for x in w]
            out_hint += ["HINT " + x for x in h]
            for _, c in containers(spec):
                image = str(c.get("image", ""))
                for p in policies:
                    if p["ns"] == ns and any(fnmatch.fnmatch(image, g) for g in p["globs"]):
                        notes.append("KYVERNO %s (%s): image %s must be signed by Jenkins; this script "
                                     "cannot verify signatures, only images built by the Jenkins pipeline "
                                     "are admitted. Policy message: %s"
                                     % (p["name"], p["file"], image, p["msg"]))
        n_err += len(out_err); n_warn += len(out_warn)
        body = ["  ERROR " + x for x in out_err] + ["  WARN " + x for x in out_warn] + \
               ["  " + x for x in out_hint + notes]
        if len(body) > MAX_LINES_PER_DOC:
            body = body[:MAX_LINES_PER_DOC] + ["  ... %d more lines not shown" % (len(body) - MAX_LINES_PER_DOC)]
        lines.append(head)
        lines += body or ["  OK"]
    verdict = "FAIL" if n_err else ("WARN" if n_warn else "OK")
    print("RESULT: %s (%d documents, %d errors, %d warnings)" % (verdict, len(expanded), n_err, n_warn))
    print("\n".join(lines))
    return 1 if n_err else 0


if __name__ == "__main__":
    sys.exit(main())
