---
name: k8s-manifest-check
description: Check Kubernetes YAML (a file or a pasted manifest) against the talos-kvm cluster before it goes to Git, with one read-only script - schema from the cluster's own OpenAPI (unknown fields, wrong types, bad enum values, CRD not installed), Pod Security level of the target namespace, the repo's Kyverno image policy, and best practices (image tag, requests/limits, probes, non-root). Use when the user asks to review, validate or fix a manifest, or asks why a pod spec is rejected.
version: 1.0.3
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, yaml, manifest, validation, pod-security, kyverno]
    category: devops
---
# Kubernetes manifest check

## When to Use
- The user gives a YAML file path, or pastes YAML, and asks whether it is correct, safe, or will be accepted.
- The user asks you to write or fix a manifest: run the check on your own draft before showing it.
- A deployment is rejected ("violates PodSecurity", "unknown field", Kyverno deny) and the user has the YAML.

## Procedure
1. Get the YAML:
   - A file path: use it as is (paths in the repo clone are under `/home/hermes/talos-gitops`).
   - Pasted YAML, or a draft you wrote: save it first with the file tool to `/tmp/manifest-<short-random>.yaml`, exactly the text, then pass that path. Do not use a heredoc: a line `EOF` inside the YAML would end it early and run the rest as shell.
   - Neither: ask once with the clarify tool as a free-text question ("file path or paste the YAML").
2. Run `bash scripts/manifest-check.sh <file-or-dash> [namespace]` with the terminal tool. The namespace argument is only used for documents without `metadata.namespace` (default `default`). Do not run kubectl first: the script already reads the schema and the namespace label.
3. First line `RESULT: OK`: say it passes in one sentence; mention HINT or KYVERNO lines if any.
4. First line `RESULT: WARN` or `RESULT: FAIL`: answer in the language the user wrote in (Vietnamese request → Vietnamese answer; keep field names and quoted lines as they are), in this order:
   - Every ERROR line, quoted, with what to change. SCHEMA errors: the API server rejects the object. PSA and POLICY errors: a Pod is rejected; a Deployment/StatefulSet/Job is accepted but its pods are never created (see the NOTE PSA / NOTE POLICY line).
   - WARN lines grouped in one short list (they do not block deploy).
   - HINT lines: explain them; they cover runtime failures that admission does not catch.
   - If you wrote the first draft yourself, still list what the first run found (one line per ERROR group) before the fix, so the user sees why each change is there.
   - If the user asked for a fix: give the corrected YAML, then save the corrected YAML to a new /tmp file, run the script again on it and show the new RESULT line. Only claim it passes if the second run says so.
5. `RESULT: SKIP`: the input is not a Kubernetes manifest (e.g. Helm values). Say so; do not invent checks.
6. Output starts with `SETUP:`, `API:` or `FILE:`, or the script fails to start: stop. Quote the line to the user and end the turn. Do not install anything (no pip, ensurepip, apt, sudo), do not read the script source, do not retry with another interpreter.

## Pitfalls
- Fixing Pod Security `restricted` needs all of: `runAsNonRoot: true`, a non-zero `runAsUser`, `seccompProfile.type: RuntimeDefault`, and per container `allowPrivilegeEscalation: false` and `capabilities.drop: [ALL]`. Fix them together, not one per round.
- An image that runs as root (e.g. the official `nginx`) does not become non-root by adding `runAsUser`/`runAsNonRoot`: it fails at runtime. Switch to an unprivileged image (e.g. `nginxinc/nginx-unprivileged`, port 8080) as the HINT says, and change the Service `targetPort` too.
- `readOnlyRootFilesystem: true` usually needs an `emptyDir` for the paths the app writes (`/tmp`, cache dirs).
- Namespaces: most are `restricted`; `vault` is `baseline`; `longhorn-system`, `monitoring`, `observability`, `velero`, `local-path-storage` are `privileged`. A namespace without a label (`default`, `argocd`) gets the cluster default `baseline`. Trust the level printed in the DOC line, not this list.
- `POLICY require-memory-request`: every container and initContainer must set `resources.requests.memory` (a cluster policy, Deny; only kube-system is exempt). Missing memory request is an error, not a style issue.
- `BLOCKED by host policy` when running the check: words inside the YAML (for example `pip` or `apt-get` in a `command:`) matched the install filter. Save the YAML to a /tmp file with the file tool and pass the path; do not tell the user a tool is missing.
- KYVERNO line: in namespace `demo` the demo-app image must be signed by Jenkins. The script cannot check signatures; the fix is to build through the Jenkins pipeline, never to add an exception.
- Image without tag in `apps/demo-app/deployment.yaml` is fine: `kustomization.yaml` sets the tag (the script prints a HINT, not a WARN).
- `apiVersion ... is not served by this cluster`: the CRD is not installed or the apiVersion is wrong (e.g. an old `v1beta1`). Do not suggest installing CRDs.
- Do not claim a manifest is valid for things the script does not check: Service selector matching pod labels, Ingress host/TLS, Helm templating, image existence.

## Verification
- Every problem mentioned is backed by a quoted ERROR/WARN/HINT line.
- A corrected YAML was re-checked with the script before it is called correct.
- No write command was run (no `kubectl apply`, `create`, `edit`, no git commit).

## Security
- The script prints field paths, not values (except enum values, image names and namespace names). Secret documents are not inspected. If the user pasted a Secret with real values, tell them it must not go into talos-gitops (public repo) and to use a SealedSecret or an ExternalSecret.
- Read-only: GET on `/openapi/v3`, `/readyz` and the namespace. Use the `hermes-readonly` kubeconfig (platform/hermes), not the admin kubeconfig.
