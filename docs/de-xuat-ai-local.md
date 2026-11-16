# Đề xuất: AI local chạy trên cloud (16/11/2026)

Trạng thái: **đổi hướng 16/11 09:07.** Anh chọn thử các model AI cloud miễn phí, tham khảo OpenRouter (mục 0). Các mục 1–9 (tự chạy model trên GCP hoặc host2) giữ lại để tham khảo, chưa tạo gì trên GCP.

## 0. Hướng mới: model miễn phí qua OpenRouter

OpenRouter là cổng API chung (dạng OpenAI `/v1/chat/completions`) tới nhiều nhà cung cấp model. Model có hậu tố `:free` không tính tiền. Khác hướng cũ: model chạy ở nhà cung cấp, lab chỉ gọi API.

Đã kiểm 16/11:

- 467 model, 17 model miễn phí (`GET /api/v1/models`, không cần key). Bỏ 2 model tạo nhạc (Lyria), còn 15 model chat, đa số có tool calling, context 256K–1M token. Ví dụ: `google/gemma-4-31b-it:free`, `nvidia/nemotron-3-ultra-550b-a55b:free`, `nvidia/nemotron-3.5-lightning:free`, `baidu/ernie-5.5-flash-preview:free`, `inclusionai/ling-3.2-flash:free`; `openrouter/free` tự chọn một model miễn phí.
- Giới hạn ([limits](https://openrouter.ai/docs/api-reference/limits)): 20 request/phút; **50 request/ngày** nếu chưa từng nạp credit, 1.000 request/ngày nếu đã nạp từ 10 credit. Tài khoản âm tiền thì model miễn phí cũng lỗi.
- Dữ liệu ([privacy](https://openrouter.ai/docs/features/privacy-and-logging)): mỗi nhà cung cấp có chính sách riêng, cài đặt riêng cho model trả phí và miễn phí. Model miễn phí và bản preview có thể lưu hoặc dùng prompt để huấn luyện. **Không gửi IP, tên máy, secret, cấu hình hay tài liệu công ty.**
- Danh sách model miễn phí đổi theo tuần (nhiều bản preview), không nên ghim cứng một model cho thứ cần ổn định.

Kế hoạch thử:

1. Hưng tạo tài khoản OpenRouter và API key (không nạp tiền, đặt credit limit của key là 0). Key chỉ để trong biến môi trường trên laptop, không vào repo.
2. Script so sánh 6 model × 4 câu (giải thích tiếng Việt, gỡ lỗi Kubernetes, viết YAML, tóm tắt), 24 request, dưới hạn 50/ngày. Đo thời gian trả lời, token/s, lưu câu trả lời để chấm: đúng kỹ thuật, tiếng Việt tự nhiên, theo đúng yêu cầu định dạng.
3. Ghi kết quả vào mục 0 này, chọn 1–2 model.
4. Nếu anh muốn dùng tiếp trong lab: Open WebUI trong cụm (Argo CD), nối tới OpenRouter bằng OpenAI API, key trong Vault qua ExternalSecret, đăng nhập Keycloak qua oauth2-proxy, `https://ai.talos.internal`. Không tốn GCP, Open WebUI cần khoảng 0,5–1 GB RAM (đặt trên w3).

Kết quả thử: chưa chạy.

## 1. Mục tiêu

Yêu cầu của anh ngày 16/11: "triển khai 1 AI local qua cloud". Em hiểu là:

- Tự chạy một LLM mã nguồn mở (trọng số tải về, chạy bằng Ollama hoặc llama.cpp), **không gọi API** OpenAI, Claude, Gemini. Câu hỏi và tài liệu không rời khỏi hạ tầng của lab.
- Máy chạy model nằm trên GCP (project của lab), người dùng mở từ LAN như các công cụ khác: `https://ai.talos.internal`, đăng nhập Keycloak.
- Có giao diện chat (Open WebUI); nếu cần thì có API kiểu OpenAI (`/v1/chat/completions`) cho app demo.

## 2. Ràng buộc đã kiểm (16/11)

| Ràng buộc | Kết quả | Nguồn |
|---|---|---|
| GPU trong Free Trial | Không được. Trial không cho gắn GPU, không cho xin tăng quota. Quota project: `GPUS_ALL_REGIONS = 0` | [Free Trial](https://docs.cloud.google.com/free/docs/free-cloud-features), `gcloud compute project-info describe` |
| Muốn GPU | Phải nâng lên tài khoản trả tiền (thẻ bị tính tiền thật khi hết credit). **Quyết định của anh, em không bấm Upgrade** | như trên |
| vCPU còn trống | `CPUS_ALL_REGIONS` 24, đang dùng 5; asia-southeast1: E2 24, C3 18. Thêm VM 4 vCPU không vướng quota | `gcloud compute regions describe` |
| Giá asia-southeast1 (on-demand) | E2: 0,026909 USD/vCPU/h + 0,003606 USD/GB/h → **e2-standard-4 (4 vCPU, 16 GB) 0,165 USD/h**, Spot 0,099 USD/h. c3-standard-4 0,249 USD/h. Đĩa pd-balanced 0,11 USD/GB/tháng | Cloud Billing Catalog API (SKU Compute Engine, 16/11) |
| Giá GPU (tham khảo, cần tài khoản trả tiền) | T4 0,37 USD/h, L4 0,69 USD/h, **chưa tính VM** | như trên |
| Ollama | Image `ollama/ollama`, API cổng 11434, **không có xác thực** → chỉ nghe 127.0.0.1 | [github.com/ollama/ollama](https://github.com/ollama/ollama) |
| Open WebUI đăng nhập SSO | Có 2 cách: (1) OIDC trực tiếp (`OPENID_PROVIDER_URL`, `ENABLE_OAUTH_SIGNUP`...): server Open WebUI **tự gọi endpoint token** của Keycloak; (2) **trusted header** (`WEBUI_AUTH_TRUSTED_EMAIL_HEADER`) sau một proxy xác thực như oauth2-proxy, tài liệu yêu cầu chỉ proxy đó tới được Open WebUI | [docs.openwebui.com SSO](https://docs.openwebui.com/features/authentication-access/auth/sso.md) |

Sửa so với bản phác buổi sáng:

- e2-standard-4 chạy theo lịch 08:15–17:15 (khoảng 196 h/tháng) là **khoảng 37 USD/tháng**, không phải 25–30.
- "w3 không SSO được" chỉ đúng với OIDC trực tiếp. Dùng oauth2-proxy trong cụm (đã có mẫu cho Prometheus, Alertmanager, VictoriaLogs) thì Open WebUI ở đâu cũng không cần tới `keycloak.talos.internal`.
- Tốc độ CPU ước thấp hơn: e2-standard-4 là 4 vCPU = 2 nhân vật lý (hyperthread), suy luận LLM trên CPU bị giới hạn bởi băng thông RAM.

RAM model (lượng tử 4-bit Q4_K_M, số gần đúng theo dung lượng file trên Ollama, cộng thêm 0,5–1 GB khi chạy):

| Model ví dụ | File | Ước tốc độ trên e2-standard-4 (cần đo) |
|---|---|---|
| `llama3.2:3b` | khoảng 2 GB | sinh 5–10 token/s |
| `gemma3:4b`, `qwen3:4b` | khoảng 2,5–3,3 GB | 4–8 token/s |
| `qwen2.5:7b`, `qwen3:8b`, `llama3.1:8b` | khoảng 4,7–5,2 GB | 2–4 token/s |

Lưu ý: ngoài tốc độ sinh còn tốc độ **đọc prompt** (prefill). Trên CPU, prompt dài 2.000 token (hỏi đáp tài liệu) có thể mất 30–90 giây trước khi ra chữ đầu tiên. Nếu anh muốn hỏi đáp tài liệu thì đây là điểm phải đo.

## 3. Ba cách

**A. VM riêng `ai-1` trên GCE.** e2-standard-4 16 GB, Debian 12, đĩa 30 GB, tạo bằng Terraform (`infra/gcp/compute.tf`). Trên VM chạy Docker Compose: Ollama + Open WebUI, cả hai chỉ nghe 127.0.0.1. host2 giữ thêm một tunnel SSH (như `gcp-tunnel-jenkins`), đi qua jenkins-1 làm jump host tới IP nội bộ VPC của `ai-1`, nên không cần IP tĩnh. Trong cụm: oauth2-proxy `ai` (nhóm `talos-admins`, `talos-viewers`) làm reverse proxy tới cổng tunnel, gửi `X-Forwarded-Email`; Open WebUI bật trusted header. Ingress `ai.talos.internal` với cert CA nội bộ.

**B. Chạy trong cụm, trên w3.** Ollama + Open WebUI cài bằng Argo CD (Helm), `nodeSelector` w3, model lưu trên PV local-path của w3. oauth2-proxy như A. w3 hiện là e2-standard-2 (2 vCPU, 8 GB, request RAM 38 %): chỉ chạy được model 3B, rất chậm; muốn 7B phải nâng w3 lên e2-standard-4 (đổi `machine_type`, phải tắt w3).

**C. Cloud Run.** Container Ollama (CPU) scale về 0, trả tiền theo giây khi có request. Mỗi lần khởi động lạnh phải nạp model 2–5 GB (30–60 giây trở lên). URL mặc định là public, muốn chỉ LAN thì phải thêm IAP hoặc load balancer; khó gắn vào mô hình `*.talos.internal` hiện tại.

| | A. VM riêng | B. Trên w3 | C. Cloud Run |
|---|---|---|---|
| Cấu hình | e2-standard-4, 16 GB, đĩa 30 GB | w3 hiện tại (3B) hoặc nâng lên e2-standard-4 | tối đa 8 vCPU / 32 GB mỗi instance, không GPU (trial) |
| Model chạy được | 3–8B | 3B (hiện tại), 3–8B nếu nâng w3 | 3–8B, nạp lại mỗi lần lạnh |
| Chi phí / tháng | khoảng 37 USD theo lịch 08:15–17:15; Spot khoảng 24; chỉ bật khi dùng (khoảng 40 h) khoảng 10 | 0 (3B) hoặc +16 USD (nâng w3) | theo giờ dùng, ít dùng thì rẻ nhất |
| Truy cập từ LAN | tunnel host2 + Ingress, giống Jenkins/GitLab | Ingress thường, traffic đi qua KubeSpan | URL public, cần thêm lớp chặn |
| SSO Keycloak | oauth2-proxy trong cụm + trusted header | như A | IAP (Google account), không phải Keycloak |
| Bảo mật | không mở cổng ra Internet; Ollama, Open WebUI chỉ nghe 127.0.0.1 | trong cụm, theo PSA/Kyverno sẵn có | thêm một điểm public phải bảo vệ |
| Ảnh hưởng cụm | không: tải CPU nằm ở VM riêng | **có**: suy luận dùng hết CPU w3, nơi chạy Prometheus, VictoriaLogs, Argo CD controller | không |
| Vận hành | thêm 1 VM, 1 tunnel; cập nhật image tay hoặc script | GitOps đầy đủ (Argo CD) | ít việc nhất, nhưng cold start chậm |
| Học được | Terraform VM, Docker Compose, tunnel, oauth2-proxy | Helm/Argo CD, giới hạn tài nguyên pod | serverless |

## 4. Đề xuất

**Cách A**, e2-standard-4, **chưa đưa vào lịch 08:15–17:15**: chỉ bật khi dùng (`gcloud compute instances start ai-1`), khoảng 10 USD/tháng. Nếu anh muốn dùng thường xuyên thì gắn vào `jenkins-office-hours` (khoảng 37 USD/tháng).

Lý do:

- Tách tải suy luận khỏi cụm. Chạy LLM trên w3 sẽ ăn hết CPU của node đang giữ Prometheus và Argo CD, dễ thành sự cố giám sát.
- Truy cập và đăng nhập dùng lại đúng mẫu đã chạy ổn (tunnel host2 + oauth2-proxy), không mở thêm cổng ra Internet.
- 16 GB đủ cho model 8B kèm Open WebUI; muốn nhanh hơn thì đổi `machine_type` (vd c3-standard-4) bằng Terraform, không phải dựng lại.

Chi phí credit: hiện khoảng 72 USD/tháng (62 USD sau 10/11, cộng khoảng 10 USD vì T2/T4 chạy cả ngày từ 16/11). Thêm A theo lịch thì khoảng 109 USD/tháng; credit còn tới 22/01/2027 (khoảng 2,2 tháng). Cần xem số dư thật trong Billing trước khi chọn chạy theo lịch.

Điểm cần chấp nhận ở A: Open WebUI tin header `X-Forwarded-Email`. Ai tới được cổng tunnel trên host2 (pod trong cụm, user trên host2) có thể giả header. Giảm bằng: không cho header đặt quyền admin (không dùng `WEBUI_AUTH_TRUSTED_ROLE_HEADER`), user mới mặc định `user`, admin gán tay. Muốn chặt hơn thì chuyển sang OIDC trực tiếp, nhưng khi đó VM phải tới được Keycloak (thêm tunnel ngược và CA nội bộ trên VM).

## 5. Bảo mật, dữ liệu

- Không mở cổng nào của `ai-1` ra Internet; firewall hiện có chỉ cho SSH từ IP văn phòng. VM vẫn có IP công khai tạm để tải model và cập nhật (không nhận kết nối vào).
- Ollama không có xác thực: bind 127.0.0.1:11434, không publish ra ngoài container network.
- Open WebUI: `WEBUI_SECRET_KEY` tạo trên VM, không vào repo; tắt telemetry (`ANONYMIZED_TELEMETRY=false`); tắt đăng ký bằng mật khẩu, chỉ vào qua oauth2-proxy.
- Lịch sử chat lưu trên đĩa VM (SQLite trong volume Open WebUI). Lab không lưu dữ liệu thật; không đưa vào backup Velero.
- Model chỉ dùng loại có license cho phép dùng nội bộ (Qwen, Gemma, Llama đều được cho lab). Ghi rõ tên và tag model trong runbook.

## 6. Việc phải làm nếu chọn A

1. Terraform: `google_compute_instance.ai_1` (e2-standard-4, đĩa 30 GB pd-balanced, không IP tĩnh, startup script cài Docker), không gắn lịch ở bước đầu.
2. Repo: `infra/gcp/ai/docker-compose.yml` (Ollama, Open WebUI, ghim tag image), script cài trên VM.
3. host2: `gcp-tunnel-ai.service` (`-J` qua jenkins-1, `-L 10.10.10.1:18090:127.0.0.1:8080`).
4. Cụm: thêm vào `platform/oauth2-proxy` một Deployment `ai` (upstream `http://10.10.10.1:18090`, redirect `https://ai.talos.internal/oauth2/callback`) + Ingress; thêm redirect URI vào client `oauth2-proxy` trong Keycloak.
5. Hosts LAN: thêm `ai.talos.internal` vào `docs/truy-cap.md`.
6. Cảnh báo: probe HTTP tới Open WebUI qua tunnel (giống Jenkins), chỉ báo khi VM đang bật.

## 7. Kế hoạch đo thử (vài giờ, dưới 1 USD)

Mục đích: có token/s thật để chọn model và machine type trước khi dựng A.

- VM tạm `ai-bench` tạo bằng `gcloud` (không vào Terraform vì xoá trong ngày; ghi vào nhật ký), zone asia-southeast1-b, Debian 12, đĩa 30 GB.
- Đo trên e2-standard-4 (khoảng 2 h, 0,33 USD), rồi đổi sang c3-standard-4 (khoảng 1 h, 0,25 USD) để so.
- Cài Ollama, chạy `ollama run <model> --verbose` với 3 model (3B, 4B, 7–8B), mỗi model 2 câu: câu ngắn tiếng Việt và prompt khoảng 1.500 token. Ghi `prompt eval rate`, `eval rate`, RAM (`free -m`), thời gian ra chữ đầu.
- Xoá VM ngay sau khi đo, kiểm `gcloud compute instances list` chỉ còn 3 VM cũ và `terraform plan` vẫn `No changes`.
- Ghi kết quả vào mục 9 của file này.

## 8. Câu hỏi cho anh

1. AI dùng để làm gì: chat thử, hỏi đáp tài liệu nội bộ (RAG), hay API cho app demo? RAG cần đo thêm tốc độ đọc prompt.
2. Chạy CPU, trả lời chậm (vài token/giây với model 7–8B) có được không, hay anh muốn nâng tài khoản để dùng GPU (T4 khoảng 0,37 USD/h chưa tính VM, tiền thật khi hết credit)?
3. Bật khi cần hay chạy theo giờ làm (thêm khoảng 37 USD/tháng credit)?

## 9. Kết quả đo

Chưa đo.
