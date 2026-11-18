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
- Skill viết trong repo (`tools/hermes-skills/`), host2 trỏ `external_dirs` vào bản clone chỉ đọc `~/talos-gitops`. Sửa skill = commit + pull, mentor xem được.
- Bước sau (nếu anh muốn): gateway Telegram dùng bot riêng, chỉ nhận lệnh từ chat của nhóm.

## 5. Ba skill đầu

| Skill | Script làm gì | LLM làm gì |
|---|---|---|
| `talos-cluster-health` | Node Ready, app Argo CD không Healthy/Synced, volume Longhorn không healthy, pod restart nhiều, Vault sealed; in tối đa 30 dòng | Tóm tắt, chỉ ra mục đỏ |
| `k8s-pod-triage <ns> <pod>` | `describe` (Events, Last State, exit code), `logs --previous --tail=80`, events namespace; lọc dòng giống secret | Đoán nguyên nhân, đề xuất lệnh kiểm tiếp (không tự chạy lệnh ghi) |
| `k8s-manifest-check <file\|->` | Schema từ OpenAPI v3 của chính cụm (thay `kubeconform`, host2 không có), Pod Security theo nhãn namespace, policy Kyverno đọc từ repo (thay `kyverno apply`), kiểm non-root/tag `latest`/thiếu probe, gợi ý image chạy root | Giải thích lỗi, sửa YAML rồi kiểm lại. Đúng lỗi các model mắc ở câu nginx 16/11 |

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
