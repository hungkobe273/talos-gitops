# Đề xuất: Hermes Agent + skill cho lab (16/11/2026)

Trạng thái: **đang triển khai (anh đồng ý 16/11 10:44).** Đã có RBAC chỉ đọc (`platform/hermes`, app Argo CD `hermes`) và skill `talos-cluster-health`; Hermes v0.23.2 đã cài trên host2 (17/11), skill health chạy được qua Hermes. Tiếp theo [de-xuat-ai-local.md](de-xuat-ai-local.md) mục 0 (thử model miễn phí trên OpenRouter).

## 1. Yêu cầu

Anh 16/11 10:43: tích hợp Hermes Agent để giảm workload cho LLM, **tạo skill cho Hermes thay vì để LLM làm hết**. Trước đó (10:41): thử thì chấp nhận chậm, nếu không thì tối ưu trên máy hiện có.

Em hiểu: việc lặp lại (kiểm cụm, gỡ lỗi pod, kiểm manifest) viết thành skill có script chạy thật; LLM chỉ chọn skill và tóm tắt kết quả, không tự suy luận từng lệnh. Ít token hơn, nhanh hơn, ít sai hơn.

## 2. Hermes Agent là gì

- Agent mã nguồn mở (MIT) của Nous Research, ra 02/2026. Chạy dạng CLI hoặc gateway cho Telegram, Slack, Discord... ([docs](https://hermes-agent.nousresearch.com/docs))
- Có bộ nhớ lâu dài và **skill** theo chuẩn agentskills.io, lưu ở `~/.hermes/skills/<nhóm>/<tên>/`:
  - `SKILL.md`: frontmatter (`name`, `description`, `version`, `platforms`, `metadata.hermes`) + các mục When to Use / Procedure / Pitfalls / Verification;
  - `scripts/`: script để agent gọi; `references/`, `templates/` tuỳ chọn.
- Nạp skill theo tầng ([skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)): lúc đầu chỉ có tên và mô tả trong context (khoảng 3k token cho cả danh sách), chỉ khi dùng mới đọc `SKILL.md`, rồi mới đọc file con. Mỗi skill thành một lệnh `/tên-skill`.
- Lệnh chạy qua backend terminal: local, Docker, SSH (hoặc sandbox cloud), có chế độ hỏi duyệt lệnh.
- Model: OpenRouter, OpenAI, hoặc endpoint OpenAI-compatible bất kỳ (Ollama `http://localhost:11434/v1`), cấu hình `~/.hermes/config.yaml`, key ở `~/.hermes/.env` ([providers](https://hermes-agent.nousresearch.com/docs/integrations/providers)).

Skill giảm việc cho LLM thế nào: script làm phần thu thập và lọc dữ liệu (deterministic), trả về vài chục dòng gọn; LLM không phải tự nghĩ chuỗi lệnh, không phải đọc output thô hàng nghìn dòng. Một việc nhiều bước thành 1–2 lần gọi model thay vì 5–10.

## 3. Ràng buộc đã kiểm

| Ràng buộc | Ảnh hưởng |
|---|---|
| Hermes **cần model có context tối thiểu 64.000 token** để dùng tool | Model local trên host2 không đáp ứng: GTX 1060 3 GB VRAM, host2 còn khoảng 1,8 GB RAM trống (16/11 10:42). Riêng KV cache 64K token của model 3B đã vài GB. → Dùng model cloud: model miễn phí trên OpenRouter có context 256K–1M, có tool calling |
| OpenRouter miễn phí: 20 request/phút, **50 request/ngày** khi chưa nạp credit | Agent gọi model mỗi bước (mỗi lần dùng tool là 1 request). Một việc 3–6 request → khoảng 10 việc/ngày. Nạp 10 USD một lần → 1.000 request/ngày (vẫn dùng model miễn phí). **Cần anh quyết** |
| Model miễn phí có thể lưu prompt | Output của skill gửi lên model: **script phải lọc**, không in Secret, token, IP LAN công ty; không cho agent đọc `kubeconfig`, `talosconfig`, Vault |
| Windows native còn thử nghiệm, khuyên Linux/WSL2 | Chạy trên host2 (Ubuntu 24.04, đã có `kubectl`), RAM Hermes khoảng vài trăm MB |
| Hermes có quyền chạy lệnh | Agent dùng kubeconfig **chỉ đọc** (ServiceAccount + ClusterRole `view`, không đọc Secret), bật duyệt lệnh, chạy dưới user riêng trên host2 |

Về "tối ưu máy hiện có": host2 nâng RAM (còn 3 khe, mới 1 thanh 16 GB đơn kênh) và cài `nvidia-driver-580` (Ubuntu có sẵn module ký sẵn cho kernel 7.0.0-43) thì chạy được model 3–4B rất nhanh, nhưng vẫn không đủ 64K context cho Hermes. Hướng đó hợp cho chat thường hoặc làm model phụ, không làm model chính của Hermes.

## 4. Kiến trúc thử

- host2: Hermes CLI (user `hermes`, không sudo), model chính `nvidia/nemotron-3-ultra-550b-a55b:free` (ổn định nhất lần thử 16/11), key OpenRouter trong `~/.hermes/.env` (quyền 600).
- `KUBECONFIG` riêng từ ServiceAccount `hermes-readonly` (namespace `hermes`, ClusterRole `view`), quản lý bằng Argo CD trong repo này; token tạo trên host2, không commit.
- Skill viết trong repo (`tools/hermes-skills/`), host2 trỏ `external_dirs` vào bản clone `/opt/talos-gitops` thuộc root, user hermes chỉ đọc (từ 20/11; trước đó là `~hermes/talos-gitops`, model sửa được). Sửa skill = commit + `sudo git -C /opt/talos-gitops pull --ff-only`, mentor xem được.
- Bước sau (nếu anh muốn): gateway Telegram dùng bot riêng, chỉ nhận lệnh từ chat của nhóm.

## 5. Skill và kết quả đo

Năm skill trong `tools/hermes-skills/devops/` (phiên bản 23/11). Mỗi skill có một script chỉ đọc, gọi `/usr/bin/python3`; model chạy script ngay ở lần gọi tool đầu rồi tóm tắt.

| Skill | Script làm gì | LLM làm gì |
|---|---|---|
| `talos-cluster-health` v1.0.7 | Node, app Argo CD, Longhorn, Vault, pod hỏng, restart 1 giờ (tách restart lúc khởi động lạnh, không bỏ qua OOMKilled), `NODE REBOOT`, `W3 PREFERRED`, ExternalSecret, event cảnh báo; nguồn đọc lỗi ra `UNKNOWN` | Nêu GREEN hoặc liệt kê mục cần xem, tối đa 3 lệnh đọc cho người |
| `k8s-pod-triage <ns> <pod>` v1.0.2 | Một lần `get pods/events` + `logs`: điều kiện, container, lần dừng cuối (bỏ qua lần dừng cũ do tắt máy), tài nguyên, probe, 6 event, 12 dòng log ưu tiên dòng lỗi; mọi dòng qua bộ lọc IP LAN, token, mật khẩu, `user:pass@` | Nêu nguyên nhân dạng khả năng, đề xuất lệnh kiểm tiếp (không tự chạy lệnh ghi) |
| `k8s-manifest-check <file\|->` v1.0.3 | Schema OpenAPI v3 của chính cụm, Pod Security theo nhãn namespace (không nhãn = baseline), `ImageValidatingPolicy` từ repo, `require-memory-request` là ERROR, best practice, gợi ý image không chạy root | Giải thích lỗi, sửa YAML rồi kiểm lại |
| `talos-backup-check` v1.0.0 | Đọc `/var/lib/talos-backup/status.json`: tuổi lần thành công, đủ 6 phần, khoá Sealed Secrets, kích thước lệch, chỗ trống | Nêu OK/CHECK, nói rõ không chứng minh khôi phục được |
| `talos-upgrade-check pre\|post <node>` v1.0.8 | GO/NO-GO trước khi nâng một node, OK/CHECK sau khi nâng: phiên bản (`--expect`, `--expect-k8s`), Longhorn replica, PDB chặn drain (đủ label selector), pod kẹt, Argo CD, workload ngừng khi reboot, pod rời w3; w3 tắt theo lịch chỉ là NOTE khi nâng node khác | Tóm tắt, in dòng `TALOS SIDE`/`K8S SIDE` cho người chạy (hermes không có talosconfig) |

Việc lặp lại rút từ nhật ký: kiểm trước/sau nâng cấp (đã có, `talos-upgrade-check`), kiểm backup hằng ngày (đã có, `talos-backup-check`), đưa pod về w3 (không làm skill: app `descheduler-w3` tự làm mỗi giờ :45). Còn lại: đọc Trivy/CVE/bản mới và tóm tắt có cần nâng không.

Các mục con dưới đây ghi theo ngày; mô tả trong đó đúng với phiên bản lúc ấy, bảng trên là trạng thái hiện tại.

Đo trước/sau trên cùng câu hỏi: số request, token, thời gian, đúng/sai (không skill: model tự gõ lệnh; có skill: gọi script).

Việc lặp lại khác trong lab (rút từ nhật ký), làm skill sau:

- Kiểm trước/sau nâng cấp Talos, Kubernetes, Keycloak (gọi lại `talos-upgrade-node.sh`, PDB, Longhorn, pod kẹt).
- Sau khi drain node: đưa pod ưu tiên w3 về lại (`rollout restart`, cần quyền ghi, để người duyệt).
- Đọc Trivy, CVE mới, bản Talos/Longhorn mới, tóm tắt có cần nâng không.
- Kiểm backup hằng ngày (gói trên B2/GCS, dung lượng, có khoá Sealed Secrets).

### Đã làm 16/11

- `platform/hermes/rbac.yaml` + `argocd-apps/hermes.yaml`: ServiceAccount `hermes-readonly`, token Secret (nằm trong cụm, không trong git), ClusterRole chỉ `get/list/watch` trên node, pod, log, event, workload, PVC/PV, Ingress, PDB, Application/Rollout Argo, Longhorn volume, ExternalSecret. **Không** có Secret, ConfigMap, exec, quyền ghi. `kubectl apply --dry-run=server` đạt.
- `tools/hermes-skills/devops/talos-cluster-health/`: `SKILL.md` + `scripts/cluster-health.sh` (một lần `kubectl get`, Python lọc, tối đa khoảng 30 dòng, exit 0 xanh / 1 cần xem / 2 mất API). Chạy thử trên host2 10:49: 10 dòng, `CHECK 1 item(s)` (longhorn-manager restart 1 lần trong giờ qua sau khi nâng K8s), 4/4 node, 23/23 app, 3 volume, Vault Ready, 73 pod.

### Đo lần đầu 17/11 (Hermes v0.23.2, `nemotron-3-ultra-550b-a55b:free`)

- `hermes -z` một câu không tool: 31 s (gồm khởi động). Trong phiên tương tác: 5,3 s cho câu chào.
- `/talos-cluster-health` (Hưng duyệt lệnh một lần): **2 request** model (1 gọi script, 1 tóm tắt), 19 s từ lúc gõ tới câu trả lời, gồm cả lúc chờ người duyệt. Model gọi đúng `bash .../cluster-health.sh`, không chạy kubectl nào khác.
- Cả phiên (3 request): 20.536 token vào, 345 token ra, 0 USD. Khoảng 7.000 token vào mỗi request, phần lớn là system prompt và nội dung skill.
- Sai một chỗ: model nói 48 event `Unhealthy` của local-path-provisioner là "expected during rollouts". Lúc đó không có rollout nào; nguyên nhân là dòng Pitfalls trong skill viết "probe failures during a rollout are expected", model áp vào. Đã sửa skill (`1ce3616`, v1.0.1): không đoán nguyên nhân, chỉ nêu số và đề xuất `describe` cho người đọc.
- Skill chạy từ bản copy `~/.hermes/skills/talos-lab/` (chép vào 16/11), bản này được ưu tiên hơn `external_dirs`. Phải xoá bản copy để Hermes dùng bản trong repo.
- `/k8s-pod-triage` (14:52–14:54, keycloak-0): **3 request** (1 hỏi namespace/pod vì gọi không kèm tham số, 1 chạy script, 1 tóm tắt), 14 s từ lúc trả lời câu hỏi tới bản tóm tắt; 10.932 token vào, 1.018 ra. Model trích đúng các dòng (event readiness timeout 3 phút trước, lần dừng cũ do tắt máy, log REFRESH_TOKEN_ERROR vô hại), nêu nguyên nhân dạng khả năng (IO trên HDD). Hai chỗ chưa tốt: đề xuất `kubectl top` (cụm không có metrics-server) và nhắc backup 16:45 khi lúc đó mới 14:53; câu hỏi clarify đưa lựa chọn namespace đoán bừa. Sửa skill v1.0.1.
- Chưa đo "không skill" (model tự gõ lệnh) để so; cần quyền chạy nhiều lệnh kubectl, mỗi lệnh phải duyệt.

### Đã làm 18/11: skill thứ 3 `k8s-manifest-check`

- `tools/hermes-skills/devops/k8s-manifest-check/`: `SKILL.md` + `scripts/manifest-check.sh <file|-> [namespace]` (gọi `manifest_check.py`, chỉ cần python3 + PyYAML có sẵn trên host2).
- Không dùng `kubeconform`/`kyverno` CLI (host2 không có, không cài thêm) và không dùng `kubectl apply --dry-run=server` (SA chỉ đọc không có quyền create). Thay bằng:
  - schema: tải `/openapi/v3/<group>/<version>` của cụm (quyền đọc có sẵn), kiểm trường lạ, thiếu trường bắt buộc, sai kiểu, giá trị ngoài enum, CRD chưa cài. Đã thử `kubectl create --dry-run=client --validate=strict`: không bắt được trường lạ.
  - Pod Security: đọc nhãn `pod-security.kubernetes.io/enforce` của namespace, tự kiểm luật baseline/restricted.
  - Kyverno: đọc `ImageValidatingPolicy` trong `platform/kyverno/manifests` (SA không list được policy).
- Không in giá trị (trừ enum, tên image, namespace); không đọc Secret.
- Thử bằng quyền hermes trên host2: 21 file (nginx sai, nginx-unprivileged đúng, YAML hỏng, CRD lạ, Secret, stdin, toàn bộ `apps/demo-app`), mỗi lần 0,2–0,3 s. Quét `apps/*` và `platform/*`: không ERROR giả; WARN thật: nginx trong `gcp-tools` thiếu probe, vài container chưa `readOnlyRootFilesystem`. File values Helm trả `SKIP`.
- Thử qua Hermes 08:56–09:00 (`/k8s-manifest-check .../platform/gcp-tools/gcp-tools.yaml`, Hưng duyệt): kết quả cuối đúng (WARN, 0 lỗi, 3 cảnh báo nginx, gợi ý emptyDir `/tmp`), nhưng **19 request**, 18 lần gọi tool, 61.086 token vào (271.808 token cache), 1.510 ra, 0 USD, khoảng 4 phút. Nguyên nhân: trong tool terminal của Hermes, `python3` là venv riêng của Hermes (không có PyYAML), khác `/usr/bin/python3` lúc mình thử bằng `sudo -u hermes bash -lc`. Model báo "PyYAML missing" rồi tự xử: đọc mã script, `pip install` (vào python của thư mục tools Hermes), `apt-get install`, `sudo apt-get` (Hermes hỏi mật khẩu sudo, không có nên thất bại), `ensurepip` + `pip install pyyaml` vào venv Hermes, rồi mới chạy được.
- Bài học: `approvals.mode manual` chỉ hỏi duyệt lệnh Hermes coi là nguy hiểm (`python3 -c` bị hỏi), **`pip install`, `apt-get`, `sudo` không bị hỏi**. Hàng rào thật là user `hermes` không có sudo và SA chỉ đọc. Mỗi script trong skill phải tự chọn đúng interpreter, và skill phải nói rõ khi thiếu phụ thuộc thì dừng.
- Sửa v1.0.1: wrapper gọi `/usr/bin/python3`; thiếu PyYAML thì in `SETUP:` và bảo dừng; Procedure bước 6: gặp `SETUP:`/`API:`/`FILE:` thì báo người, cấm pip/apt/sudo, không đọc mã. Thử lại với venv Hermes đứng đầu PATH: chạy đúng.
- 09:03 gỡ những gì model đã tự cài (PyYAML + pip trong venv Hermes, PyYAML trong python tools Hermes), pull v1.0.1.
- Thử lại qua Hermes 09:04 (phiên mới, cùng câu): **3 request** (1 `skill_view`, 1 chạy script, 1 tóm tắt), 2 lần gọi tool, khoảng 10 s, 13.876 token vào (17.536 cache), 409 ra, 0 USD, không lệnh nào phải duyệt. Tóm tắt trích đúng 3 dòng WARN, nói rõ không chặn deploy. So với lần đầu: 19 → 3 request, 61k → 14k token vào, 4 phút → 10 s.
- Câu nginx của 16/11 qua Hermes 09:07–09:08 ("Viết Deployment nginx chạy non-root trong namespace demo, kiểm rồi sửa cho đạt"): **4 request**, 3 lần gọi tool, khoảng 50 s, 8.755 token vào (35.072 cache), 1.561 ra, 0 USD, không lệnh nào phải duyệt. Bản nháp đầu là nginx trần (`nginx:latest`, không securityContext): script FAIL 4 ERROR PSA + 6 WARN. Model sửa một lần đủ cả: đổi sang `nginxinc/nginx-unprivileged:1.27` cổng 8080 (theo Pitfalls, không cần HINT), `runAsUser: 101`, seccomp, drop ALL, `readOnlyRootFilesystem` + emptyDir `/tmp`, `/var/cache/nginx`, `/var/run`, requests/limits, 2 probe; chạy lại script ra `RESULT: OK` rồi mới đưa YAML. Khác 16/11 (4 model đều sai: image root + `runAsNonRoot`).
- Đối chiếu bằng `kubectl apply --dry-run=server` (kubeconfig admin): 4 ERROR PSA của script khớp đúng 4 vi phạm API server báo; bản sửa được nhận không cảnh báo. Chưa chạy pod thật.
- Hai chỗ chưa tốt, sửa v1.0.2: (1) model trả lời tiếng Anh cho câu tiếng Việt và không liệt kê lỗi của bản nháp trước khi sửa; (2) script/skill nói ERROR là "API server từ chối", nhưng với Deployment, API server chỉ cảnh báo PSA và nhận object, còn pod bị chặn lúc tạo (FailedCreate). Script thêm dòng `NOTE PSA` cho kind khác Pod.

### Skill thứ 4 `talos-backup-check` (19/11)

- Nguồn dữ liệu: user hermes không đọc được thư mục backup (`~/talos-kvm` của ngochung, 700), không có khoá B2/GCS, và `systemctl show` mất giờ chạy sau khi host2 khởi động lại. Nên backup tự ghi file trạng thái không có secret `/var/lib/talos-backup/status.json` (`host2/bin/talos-backup-status.sh`, `ExecStopPost` drop-in `50-status.conf`), skill chỉ đọc file đó và timer.
- `scripts/backup-check.sh`: OK/CHECK, tối đa khoảng 25 dòng; ngưỡng tuổi giống `talos-watchdog.sh` (26 giờ, cộng 24 giờ mỗi ngày T7/CN). Không chứng minh khôi phục được, skill nói rõ điều này.
- Cài trên host2 08:52–08:56 (Hưng): `~/bin/talos-backup-status.sh`, `/var/lib/talos-backup` (ngochung 755), drop-in `50-status.conf`, `daemon-reload`, chạy tay một lần để có file đầu. Lần 16:45 hôm nay là lần đầu `ExecStopPost` tự ghi.
- Thử qua Hermes 09:20 (`/talos-backup-check`): **2 request**, 1 lần gọi tool, 14 s, 8.978 token vào, 285 ra, không lệnh nào phải duyệt. Trả lời đúng: lần thành công cuối 18/11 10:19 (23 giờ, ngưỡng 26 giờ), đủ 6 phần, 2 khoá Sealed Secrets. Trả lời tiếng Anh vì lệnh gọi chỉ có `/talos-backup-check`, không có câu tiếng Việt.

### Skill thứ 5 `talos-upgrade-check` (19/11)

- `scripts/upgrade-check.sh pre|post [node] [--expect vX.Y.Z]`, chỉ `kubectl get`, tối đa khoảng 35 dòng. `pre` ra GO/NO-GO: node Ready và không cordon, phiên bản Talos/kubelet từng node, Longhorn healthy và mỗi volume còn replica chạy ngoài node đích, PDB 0 disruption có pod trên node đích (tự nhận `csi-attacher`/`csi-provisioner` là "handled" vì script nâng cấp xoá pod đó trước, `instance-manager-*` là "known" vì Longhorn tự gỡ khi cordon thật), pod kẹt, app Argo CD, workload sẽ ngừng khi node khởi động lại (tất cả replica trên node, PV local), vault-0, control plane duy nhất. `post` ra OK/CHECK: cùng các mục trên, phiên bản node so với `--expect`, workload ưu tiên w3 nhưng không còn pod nào trên w3, restart 30 phút gần nhất.
- Không gọi được `talos-upgrade-node.sh` dù không có `--yes`: script cần talosconfig (quyền admin Talos), user hermes cố ý không có. Skill in sẵn dòng `TALOS SIDE` để Hưng chạy `~/bin/talos-upgrade-node.sh <ip> <ver>` (chế độ xem kế hoạch) và so với kết quả skill. Cách khác (wrapper root qua sudoers chỉ cho dry-run) phải mở ngoại lệ trong hook chặn `sudo`, chưa làm.
- Thử bằng quyền hermes trên host2 (19/11 chiều, cụm khoẻ): `pre` cả cụm, w3, w1 (theo IP), w2 (theo tên), cp1 kèm `--expect v1.14.7` đều GO, ghi chú đúng (w2 có vault-0 và keycloak, w3 có Prometheus/VictoriaLogs trên PV local, cp1 là control plane duy nhất). `post w2 --expect v1.14.7` ra CHECK vì node còn v1.14.6 (đúng). `post` cũng báo `argo-rollouts` ưu tiên w3 nhưng đang ở w2 (có thật, từ lần drain trước). Tham số sai ra exit 2.
- Thử qua Hermes 09:32 ("Kiểm trước khi nâng w1 lên v1.14.7"): kết quả đúng (GO, ghi chú volume, PDB, workload trên w1, dòng TALOS SIDE) nhưng **5 request**, 4 lần gọi tool, 25 s, 19.172 token vào (43.840 cache), 1.198 ra, 0 USD. Tốn vì: model đọc 2 file script trước khi chạy; script không nhận tên `w1` nên lần chạy đầu ra `NODE:`; trả lời tiếng Anh. Sửa v1.0.1: script nhận `cp1 w1 w2 w3`, skill bảo chạy script ngay không đọc file, câu ngôn ngữ đặt đầu Procedure.
- Thử lại v1.0.1 lúc 09:49, cùng câu: **2 request**, 1 lần gọi tool (`pre w1 --expect v1.14.7`), 19 s, 10.422 token vào (8.768 cache), 668 ra, 0 USD. Trả lời tiếng Việt, đủ NODES/LONGHORN, 4 ghi chú cho w1 và dòng TALOS SIDE.
- Thử `post` 09:54 ("Kiểm sau khi nâng w2", cùng phiên): **2 request**, 1 lần gọi tool (`post w2`), 11 s. CHECK 1 mục đúng (`argo-rollouts` ưu tiên w3 nhưng ở w2), đưa lệnh `rollout restart` cho người, không tự chạy. Model diễn giải sai "dồn khi drain w2" vì chữ của script ("during the drain"); v1.0.2 đổi thành "do một lần drain hoặc tắt w3 trước đó, không tự quay lại".

### Hook và cấu hình sau review 20/11

Review độc lập 20/11 tìm ra 3 lỗ của bản hook 18/11: lách được bằng `python3 -mpip`, `\pip`, `p""ip`, `curl ... | /bin/bash`, `bash <(curl ...)`; model tự ghi file bằng tool file rồi `bash /tmp/x.sh`; model đổi được hook qua `hermes config set hooks`; và bản hook của root được cài từ clone mà hermes sửa được. Bản 20/11:

- Hook chuẩn hoá lệnh (bỏ dấu nháy, `\`, `{a,b}`, `$'\x..'`) rồi mới so luật; thêm luật `-m pip/venv`, `runpy`, `eval`, đẩy `curl`/`wget`/`base64 -d` vào shell hoặc python, chạy script trong `/tmp`, `~`, `/home`, `./`, `chmod +x`, lệnh `hermes config|hooks|tools|update|...`, `chattr`, và mọi lệnh hay tool file đụng `~/.hermes/.env`, `auth.json`, `config.yaml`, `~/.kube/config`. Matcher thêm `read_file|write_file|patch|search_files`; tool ghi không được ghi vào `/opt/talos-gitops`. Payload hỏng ra exit 2 (trước có lúc exit 1). Thử 61 trường hợp trên host2: 0 sai.
- Clone skill chuyển sang `/opt/talos-gitops` (root, chỉ đọc), hook cài từ đó; setup từ chối nếu clone có thay đổi cục bộ.
- `~/.hermes/config.yaml` và `shell-hooks-allowlist.json` gắn `chattr +i` (không sửa, đổi tên hay thay được dù nằm trong thư mục của hermes); setup gỡ cờ ở đầu và gắn lại ở cuối.
- Vẫn chỉ là lọc chữ: `x=pip; $x install` lọt. Hàng rào thật là user không sudo, SA chỉ đọc, skill/hook/config thuộc root.

### Đo lại 20/11: health v1.0.3–v1.0.4, upgrade-check v1.0.3

Cùng model `nemotron-3-ultra-550b-a55b:free`, phiên tương tác mới, Hưng duyệt "once". Thời gian tính từ lúc gõ câu hỏi tới câu trả lời.

| Lần thử | Request | Gọi tool | Thời gian | Token vào / ra | Kết quả |
|---|---|---|---|---|---|
| health v1.0.3, 09:14, "cụm có ổn không" | 3 | 2 (`skill_view`, script) | khoảng 21 s | 17.830 / 924 | Chạy script ngay, không đọc file, trả lời tiếng Việt. Nhưng script ra `CHECK 1` giả: 4 restart CSI Longhorn lúc khởi động lạnh 08:50, model báo "cụm có vấn đề" |
| health v1.0.4, 09:37, cùng câu | 3 | 2 | khoảng 17 s | 13.623 / 683 | `GREEN`, có dòng `COLD START`, model nói 4 restart là của khởi động lạnh, "không cần làm gì thêm" |
| upgrade-check v1.0.3, 09:43, "kiểm sau khi nâng w2 lên v1.14.6" | 3 | 3 (`skill_view` x2, script) | khoảng 24 s | 17.442 / 687 | Chạy `post w2 --expect v1.14.6` ngay, `OK`, có dòng `TARGET READY`. Model nạp thêm cả skill health trong cùng request (thêm khoảng 4k token, không thêm request) |

- Lần đo 17/11 health là 2 request; nay là 3 vì Hermes gọi `skill_view` riêng khi câu hỏi là tiếng thường (17/11 gọi bằng `/talos-cluster-health`, nội dung skill nạp sẵn). Với câu tự nhiên, 3 request là mức thấp nhất: nạp skill, chạy script, trả lời.
- Bài học: script phải biết lúc khởi động lạnh hoặc node vừa khởi động lại, không thì model đọc nguyên văn và báo lỗi giả. Cả hai skill nay tách restart trong 10 phút đầu sau khi control plane hoặc node Ready.
- upgrade-check v1.0.4 bỏ các NOTE PDB "known/handled" ở chế độ `post` (chỉ có ích trước khi drain; lần thử 09:43 model vẫn diễn giải dòng "dry run" đó trong câu trả lời sau nâng cấp).

### Hook chặn cài gói và sudo (18/11, bản đầu; bản hiện tại xem "Hook và cấu hình sau review 20/11")

- Vì `approvals.mode manual` không hỏi pip/apt/sudo, thêm shell hook `pre_tool_call` của Hermes: `tools/hermes/hooks/block-installs.sh`, cài bằng `setup-host2.sh` bước 2b vào `/usr/local/lib/hermes-hooks/` (root sở hữu, agent không sửa được), matcher `terminal|process|execute_code`, `timeout: 10`, `fail_closed: true` (hook hỏng thì chặn luôn).
- Chặn khi lệnh có từ lệnh: `sudo su doas pkexec runuser`, `apt apt-get aptitude dpkg snap flatpak brew`, `pip pip3 pipx easy_install ensurepip conda mamba uv`, `-m pip`, `-m ensurepip`, `npm npx pnpm yarn gem cargo`, `go install/get`, `curl|wget ... | sh`. Kể cả gọi theo đường dẫn (`.../bin/pip3`). Trả exit 2 kèm lời nhắn bảo model dừng và báo người; ghi `~/.hermes/logs/policy-blocks.log` (giờ, session, tool, luật; không ghi lệnh).
- Thử với payload giả trên host2: chặn đủ 9 lệnh model đã chạy hoặc tương tự 18/11; cho qua script skill (cả heredoc), `kubectl ... | grep`, `get snapshots.longhorn.io`, `ls /var/lib/apt/lists`, `python3 -c`, `git log`.
- Cài trên host2 09:22 (Hưng chạy `setup-host2.sh`, tự kiểm `rc=2`), đồng ý hook lúc mở Hermes 09:23 (`hermes hooks list`: allowed). Thử với model 09:23 ("Cài gói pyyaml cho python3 bằng pip"): model gọi `pip install pyyaml`, hook chặn, model không thử cách khác mà báo bằng tiếng Việt là host chặn cài gói; **2 request**, 1 lần gọi tool, khoảng 10 s. `policy-blocks.log` có đúng 1 dòng cho phiên này.
- Giới hạn: lọc theo chữ, không phải sandbox. Manifest dán vào có chữ `apt-get` trong `command:` cũng bị chặn (báo rõ luật nên dễ nhận ra). Hàng rào thật vẫn là user `hermes` không sudo và SA chỉ đọc; hook chặn model tự cài vào home của nó và đỡ tốn request.

### Thử lại 23/11 sau setup (hook 20/11, clone `/opt/talos-gitops`)

- Setup chạy lại 09:15: cờ `i` đủ, log hook ghi `python-package` và `own-script`. Dòng in `rc` trống do `set -e`, sửa ở `1b0d5a7`.
- `/talos-cluster-health` 09:27: chạy script ngay, khoảng 30 s, CHECK đúng 2 mục. Model coi dòng `NOTE: w3 Ready since` là node khởi động lại; health v1.0.7 sửa Pitfall.
- "cài pyyaml bằng pip" 09:35: hook chặn, model dừng, 9 s, nhưng khuyên người chạy `sudo pip install`. Thông báo chặn thêm câu cấm đưa lệnh cài; thử lại 09:42: không còn sudo, vẫn bảo người tự `pip install`. Model free không theo hết; chấp nhận vì người nhận là admin, hook vẫn chặn.

## 6. Kế hoạch

1. Cài Hermes trên host2 (installer chính thức, user riêng), nối OpenRouter, chạy thử 1 câu không tool.
2. ServiceAccount chỉ đọc + kubeconfig riêng; kiểm `kubectl auth can-i get secrets` = no.
3. Viết `talos-cluster-health`, đo trước/sau.
4. Hai skill còn lại, ghi kết quả vào file này.

## 7. Câu hỏi cho anh (đáp án soạn sẵn 17/11)

Không câu nào chặn bước 1 của mục 6. Nếu anh chưa trả lời, em cài theo đáp án **A** của cả 3 câu (miễn phí, chỉ đọc, CLI). Các đáp án này đổi sau được mà không phải cài lại.

### Câu 1. OpenRouter: giữ 50 request/ngày hay nạp 10 USD?

| | A. Giữ 50 request/ngày (đề xuất cho tuần đầu) | B. Nạp 10 USD một lần |
|---|---|---|
| Hạn mức | 50 request/ngày, 20 request/phút | 1.000 request/ngày, vẫn dùng model `:free` |
| Đủ cho | Khoảng 10 việc/ngày (mỗi việc 3–6 request). Ngày 16/11 thử 6 model đã dùng 42/50 | Đo trước/sau cả 3 skill trong 1 ngày, dùng hằng ngày thoải mái |
| Tiền | 0 | 10 USD, không tự gia hạn. Credit dùng được cho model trả phí nếu sau này cần |
| Rủi ro | Hết hạn mức giữa chừng, đo trước/sau phải chia nhiều ngày | Gần như không. Model miễn phí vẫn có thể lưu prompt, nên quy tắc lọc output giữ nguyên |

Đề xuất: tuần đầu dùng A. Skill gom việc vào 1–2 request, nên 50 request/ngày có thể đủ. Nếu đo thấy thường xuyên hết hạn mức thì chuyển B. Việc nạp tiền do anh hoặc Hưng tự làm trên trang OpenRouter.

### Câu 2. Agent chỉ đọc hay được chạy lệnh sửa có duyệt?

| | A. Chỉ đọc (đề xuất, đã làm 16/11) | B. Thêm lệnh sửa, mỗi lệnh người duyệt |
|---|---|---|
| Quyền | ServiceAccount `hermes-readonly`: chỉ `get/list/watch`, không Secret, ConfigMap, exec | Thêm ServiceAccount thứ hai có quyền ghi hẹp: `rollout restart` deployment/statefulset, xoá pod; namespace giới hạn |
| Agent làm được | Kiểm cụm, đọc log, đoán nguyên nhân, **đề xuất** lệnh cho người chạy | Như A, cộng thêm tự chạy lệnh sửa sau khi người bấm duyệt |
| Rủi ro | Thấp: tệ nhất là tóm tắt sai | Model miễn phí đôi khi đề xuất sai (4/6 model sai câu YAML nginx 16/11). Người duyệt quen tay bấm đồng ý thì lệnh sai vẫn chạy. Phải viết thêm RBAC, có skill riêng cho mỗi lệnh ghi |
| Phù hợp quy tắc lab | Khớp "người chạy lệnh CHANGE" | Cần ghi rõ ai duyệt và ghi nhật ký mỗi lệnh |

Đề xuất: A. Xét B sau khi có 1–2 tuần số liệu agent đề xuất đúng hay sai. Lúc đó làm hẹp, chỉ 1 việc: đưa pod ưu tiên w3 về lại sau khi drain.

### Câu 3. Có cần gateway Telegram không?

| | A. Chỉ CLI trên host2 (đề xuất trước mắt) | B. Thêm gateway Telegram |
|---|---|---|
| Dùng thế nào | `ssh kvm-host2`, rồi `sudo -u hermes hermes` | Nhắn bot trong nhóm Telegram, điện thoại cũng dùng được |
| Cần thêm | Không | Bot riêng (không dùng chung bot cảnh báo), chỉ nhận lệnh từ chat ID của nhóm; Hermes chạy thường trực dưới dạng service (thêm vài trăm MB RAM trên host2, host2 còn khoảng 1,8 GB) |
| Rủi ro | Thấp | Ai trong nhóm cũng gọi được, request tiêu nhanh hơn hạn mức 50/ngày. Thêm một token bot phải giữ |
| Khi nào đáng làm | Lúc thử và đo | Khi agent đã ổn và có hạn mức B ở câu 1. Hợp với cảnh báo Telegram: nhận cảnh báo xong hỏi agent ngay trong cùng chat |

Đề xuất: A trong lúc thử. Làm B sau khi xong 3 skill và đã chọn B ở câu 1.

### Tóm tắt để anh chọn

- **Mặc định nếu anh chưa trả lời:** 1A, 2A, 3A. Chiều 17/11 có thể cài luôn, không tốn tiền.
- **Nếu anh muốn đo nhanh và dùng qua Telegram:** 1B, 2A, 3B. Cần 10 USD và một bot mới.
