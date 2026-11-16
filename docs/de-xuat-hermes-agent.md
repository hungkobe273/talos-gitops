# Đề xuất: Hermes Agent + skill cho lab (16/11/2026)

Trạng thái: **nghiên cứu, chưa cài.** Tiếp theo [de-xuat-ai-local.md](de-xuat-ai-local.md) mục 0 (thử model miễn phí trên OpenRouter).

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
| `k8s-manifest-check <file>` | `kubeconform -strict`, `kyverno apply` với policy của cụm, kiểm non-root/tag `latest`/thiếu probe | Giải thích lỗi, sửa YAML. Đúng lỗi các model mắc ở câu nginx 16/11 |

Đo trước/sau trên cùng câu hỏi: số request, token, thời gian, đúng/sai (không skill: model tự gõ lệnh; có skill: gọi script).

## 6. Kế hoạch

1. Cài Hermes trên host2 (installer chính thức, user riêng), nối OpenRouter, chạy thử 1 câu không tool.
2. ServiceAccount chỉ đọc + kubeconfig riêng; kiểm `kubectl auth can-i get secrets` = no.
3. Viết `talos-cluster-health`, đo trước/sau.
4. Hai skill còn lại, ghi kết quả vào file này.

## 7. Câu hỏi cho anh

1. Nạp 10 USD vào OpenRouter để được 1.000 request/ngày (vẫn dùng model miễn phí) không, hay giữ 50 request/ngày?
2. Agent chỉ đọc cụm (đề xuất) hay được chạy cả lệnh sửa có duyệt?
3. Có cần gateway Telegram không, hay dùng CLI trên host2 là đủ?
