# Nhật ký thay đổi

Ghi mỗi thay đổi về hạ tầng, cấu hình cụm hoặc ứng dụng: ngày, thay đổi, lý do, commit (nếu có). Mới nhất ở trên.

Thay đổi nằm ngoài repo này (host2, cấu hình Talos) cũng ghi ở đây, vì repo không chứa file cấu hình Talos (có secret).

## 29/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Viết lại `docs/kien-truc.md` theo hiện trạng: 1 control plane, Jenkins deploy, Harbor, Kyverno, Vault, SSO Keycloak | Sơ đồ cũ (16/10) không còn đúng | `b608ba2` |
| Bổ sung nhật ký 20/10 – 28/10; viết lại `docs/bao-cao.md`, `docs/truy-cap.md` và `README.md` theo hiện trạng | Tài liệu cho anh hướng dẫn theo dõi không còn khoảng trống | `5099d39`, `d9d7d07`, commit README |
| Sự cố khởi động lạnh 08:37: PSI io full khoảng 33%, etcd chậm, API mất khoảng 1 phút, controller-manager và scheduler restart; tự hồi phục | Ghi nhận (gốc HDD), xem `bao-cao.md` mục 5 | ngoài repo |
| Sự cố 08:47–09:11: Keycloak bị startup probe kill sau 20 phút (bước build Quarkus chậm vì IO); w2 nhận gần hết pod (request RAM 88%), Talos OOM-kill 2 lần (08:58, 09:05), Grafana restart liên tục. Xử lý: xoá pod `keycloak-0` để nó sang w1; 09:11 cụm sạch, request RAM w1 39% / w2 69%. Khởi động lạnh hôm nay khoảng 50 phút | Ghi nhận; sửa gốc: request RAM sát mức dùng thật, Keycloak image optimized | ngoài repo (xoá pod tay) |

## 28/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Kyverno tin CA nội bộ (`SSL_CERT_DIR` + Secret `talos-internal-ca`), đọc chữ ký trên Harbor bằng `kyverno/harbor-pull`; policy thêm glob `harbor.talos.internal/talos/talos-demo-app*` | Cho cụm kéo image từ Harbor mà vẫn kiểm chữ ký | `f75a283`, `5660c0f` |
| Khoá ký token của Harbor chuyển sang PKCS#1, `make-secrets.sh` sửa theo | `/service/token` trả 500: Harbor chỉ đọc PKCS#1, OpenSSL 3 sinh PKCS#8 | `7036537` |
| demo-app kéo image từ `harbor.talos.internal/talos/talos-demo-app` (kustomize `newName`), giữ `ghcr-pull` để lùi | Image đi trong mạng nội bộ; ghcr vẫn là nguồn gốc | `c302399` |
| Cảnh báo `VaultNotReady` (container vault không Ready 10 phút) | Sáng 28/10 host2 mất Internet, Vault không unseal mà không có cảnh báo | `e7b9ec4` |
| Viết lại lịch sử 3 repo (talos-gitops, talos-demo-app, talos-kvm-showcase) để bỏ dòng đồng tác giả tự động; nội dung không đổi, mọi hash cũ đổi | Theo yêu cầu của Hưng | `fa5552e` (cập nhật hash trong docs) |
| Đo: khởi động lạnh 9 phút 29 giây; push tới production khoảng 12 phút (2 lượt Jenkins #19, #20 qua Harbor) | Có số liệu vận hành | ngoài repo |

## 27/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Jenkins (GCE) thành deployer chính: gitleaks, test + coverage, govulncheck, gosec, SonarQube gate, build amd64 + arm64, Trivy theo digest, SBOM, ký cosign, sửa `newTag`. Actions/GitLab chỉ build | Mentor chọn Jenkins; thêm bảo mật vào CI/CD | `dab45ce` (khoá công khai cosign), Jenkinsfile ở talos-demo-app |
| Vault 2.0 + External Secrets: tự unseal bằng GCP KMS, audit, KV v2, Kubernetes auth; demo-app lấy `.env` từ Vault; cảnh báo Vault/ESO; token chỉ để snapshot | Mentor yêu cầu Vault cho K8s | `964eccd` … `94af789` |
| Kyverno 1.19 chỉ nhận image demo-app ký bằng khoá Jenkins; chuyển từ ClusterPolicy sang ImageValidatingPolicy | Chặn image chưa qua pipeline | `6c6779a` … `62f024c` |
| ZAP baseline quét bản preview trước khi chuyển traffic; `progressDeadlineSeconds` 1800 | DAST trong blue-green | `b68b287`, `6d9c289` |
| SSO Keycloak thêm Vault, SonarQube, GitLab, Jenkins (SAML), Prometheus/Alertmanager qua oauth2-proxy | SSO tập trung | `0f86ca2`, `6922b2f`, `940a320` |
| Harbor 2.15 (registry tự host, mọi pod trên w2, PostgreSQL 18 riêng), replication từ GHCR 10 phút/lần kèm chữ ký, đăng nhập Keycloak, robot `demo-pull` | Mentor yêu cầu private registry tự host | `6663dec` … `2a9ccdf` |
| Node Talos tin CA nội bộ cho `harbor.talos.internal` và phân giải tên về host2 (patch no-reboot w2 → w1 → cp1) | Containerd kéo được image từ Harbor | ngoài repo (patch Talos) |
| Diễn tập lùi DB Keycloak về PostgreSQL trong cụm rồi tiến lại Supabase (SSO gián đoạn 3 phút 23 giây khi lùi) | Kiểm chứng kế hoạch lùi | `28c747c`, `3586331` |
| Backup 16:45 thêm dump DB Harbor và snapshot Vault vào bundle GPG lên B2 | Backup đủ các thành phần có trạng thái mới | ngoài repo (host2) |

## 23/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Keycloak chuyển DB sang Supabase (session pooler, verify-full) | Giảm tải IO cho ổ HDD duy nhất | `69cedb6` … `274a0c2` |
| Prometheus TSDB lên PVC 5Gi ghim w1, giữ 7 ngày / 3 GB | Không mất metric khi pod khởi động lại | `0cd5b4b` |

## 20/10 – 22/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Tắt cp2, cp3 (reset, giữ đĩa), còn 1 control plane | Thiếu RAM và IO trên một máy | ngoài repo |
| Argo Rollouts: demo-app blue-green, smoke test + phân tích tỉ lệ 5xx, đã thử cả bản tốt và bản lỗi | Bản mới được kiểm tra trước khi nhận traffic | `8e97cc8` … `242dab9` |
| local-path-provisioner + StorageClass `local-path-retain`; descheduler | Lưu trữ cho thành phần có trạng thái; cân bằng pod sau khi khởi động | `df38b0b`, `9b80fd1` |
| Keycloak 26 + realm talos; SSO cho Grafana, Argo CD, Headlamp; cảnh báo Keycloak, Argo CD | Một nơi đăng nhập và thu hồi quyền | `2e91f9c` … `c304240` |
| Grafana DB lên PVC ghim w2; requests/limits cho Argo CD và monitoring | Ổn định sau các lần khởi động lạnh | `f75a206`, `ad4954e`, `1769e75` |

## 16/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Grafana: request 384Mi, limit 1Gi (trước 256Mi/512Mi) | Grafana chạm limit 512Mi, đọc lại đĩa liên tục, HDD nghẽn, API cụm gián đoạn 10:34–10:45 | `3bc3f8e` |
| Backup etcd tự động trên host2: systemd timer 16:45, giữ 7 bản, báo Telegram khi lỗi | Có bản khôi phục etcd hằng ngày | ngoài repo |
| Talos `TimeSyncConfig`: lấy giờ qua KVM PTP, `bootTimeout: 2m`; host2 NTP `time.cloudflare.com` | Sáng 16/10 host mất Internet, Talos chờ đồng bộ giờ, etcd không chạy | ngoài repo |
| Thêm tài liệu `docs/` (báo cáo, kiến trúc, truy cập, nhật ký thay đổi) | Anh hướng dẫn yêu cầu đưa tài liệu lên GitHub và cập nhật theo thay đổi | `bfaa23f`, commit sau |

## 15/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Thêm Headlamp (chart 0.45.0), tài khoản `headlamp-admin` và `headlamp-viewer`, tắt binding cluster-admin mặc định | Dashboard quản trị có phân quyền | `1d03564` |
| Cảnh báo lỗi chỉ tính `GET /api/work`; Grafana chờ 5 phút trước liveness probe | Giảm cảnh báo nhầm; Grafana khởi động chậm trên HDD | `1e186b0` |
| Grafana: request 256Mi, limit 512Mi | Grafana limit 256Mi làm IO cao, 3 apiserver unready lúc 14:14 | `7f0bd6c` |
| Thêm SealedSecrets: `telegram-bot`, `grafana-admin`, `ghcr-pull` | Không để secret dạng thô trong Git | `611be31` |
| RAM control plane 2560 → 2048 MB; host2 `vm.swappiness=10`; etcd heartbeat 500 ms, election 5000 ms | Host thiếu RAM và swap, etcd trên HDD bầu leader liên tục | ngoài repo |

## 09/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Thêm README | Mô tả repo | `034757c` |
| Thêm manifest demo-app, Argo CD apps, values monitoring | Khởi tạo GitOps | `7c76128` |
