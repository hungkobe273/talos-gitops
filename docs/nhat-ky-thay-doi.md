# Nhật ký thay đổi

Ghi mỗi thay đổi về hạ tầng, cấu hình cụm hoặc ứng dụng: ngày, thay đổi, lý do, commit (nếu có). Mới nhất ở trên.

Thay đổi nằm ngoài repo này (host2, cấu hình Talos) cũng ghi ở đây, vì repo không chứa file cấu hình Talos (có secret).

## 30/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Sự cố khởi động lạnh 08:26–08:51: w2 nhận nhiều pod chạy được ở đâu cũng được (request RAM 99%), nên các pod Harbor (bị ghim vào w2) nằm Pending; Kyverno không gọi được Harbor để kiểm chữ ký (503), demo-app có 0 pod. Xử lý tay: xoá pod `argocd-application-controller-0` (768Mi, sang w1), sau đó xoá ReplicaSet demo-app đang kẹt backoff. Khởi động lạnh hôm nay khoảng 25 phút, không có OOM | Ghi nhận; sửa gốc ở dòng dưới | ngoài repo (xoá pod tay) |
| PriorityClass `talos-pinned` (value 1000, `platform/admission-policies/priority-pinned.yaml`), gắn cho mọi thành phần Harbor (portal, core, jobservice, registry, redis, exporter, postgres) | Pod bị ghim một node không tự dời được; ưu tiên cao hơn thì scheduler đẩy một pod dời được sang worker kia (preemption) thay vì để Harbor Pending | commit này |
| Gắn `talos-pinned` cho Vault và Grafana (cũng bị ghim w2 qua PV local-path). Grafana restart khi sync; Vault (OnDelete) nhận ở lần pod khởi động sau | Cùng lý do dòng trên | commit này |
| Request RAM cho Job hook `kps-kube-prometheus-stack-admission-create/-patch` (`prometheusOperator.admissionWebhooks.patch.resources`, 32Mi); sửa `messageExpression` của `require-memory-request` (hết lỗi cộng 2 list khác kiểu). Còn cảnh báo type checking `undefined field requests` nhưng policy vẫn bắt đúng vi phạm (bộ đếm apiserver). Chưa chuyển Deny | Kết quả kiểm tra của Phúc (`TTS_QTDV/design/kiem-tra-require-memory-request-30-10.md`): 2 vi phạm sáng 30/10 đều từ 2 Job hook này. Job hook mới chỉ chạy ở lần sync monitoring tới | `ac0f967` |
| `require-memory-request`: bọc `dyn(c.resources)` để trình kiểm kiểu CEL của apiserver 1.37 hết báo `undefined field requests`; `.status.typeChecking` rỗng, pod thử thiếu request vẫn bị cảnh báo (`--dry-run=server`) | Điều kiện trước khi chuyển Deny (kiểm tra của Phúc) | `d4d2e00` |
| Log tập trung (yêu cầu của anh 30/10, thiết kế Phúc `TTS_QTDV/design/log-tap-trung-otel-signoz-30-10.md`): app `victoria-logs` (chart 0.13.10, PVC 5Gi local-path-retain ghim w2, `talos-pinned`, giữ 7 ngày/4 GiB, request 192Mi) và `otel-collector` (chart 0.176.0, DaemonSet 3 node, filelog + k8sattributes, OTLP HTTP, request 64Mi); plugin Grafana `victoriametrics-logs-datasource`, datasource + dashboard "Log tập trung" (ConfigMap). Sync tay 09:37/09:40, sau đó bật automated. Kiểm: log 8 namespace về trong 15 phút, PSI io về khoảng 4%, request w1/w2 93%; `mentor_view` xem được log qua dashboard | Dùng OpenTelemetry như anh gợi ý; backend VictoriaLogs thay SigNoz vì SigNoz tự host không có SSO Keycloak và cần ClickHouse 2–4 GiB RAM (cụm không đủ, HDD làm chậm cold start). Explore của Grafana chỉ cho Editor/Admin nên viewer xem qua dashboard | `b98b690`, commit dashboard, commit này |
| Đo cold start 10:19:06 (tắt có kiểm soát theo runbook 2.2, backup tay trước, bật cp1/w1/w2 cùng lúc như autostart): API khoảng +4:20, Harbor đủ 7 pod +9:13, demo-app 2/2 +10:48; 35 pod Pending lúc 10:23 hết lúc 10:28; PSI io đỉnh 35%. Không can thiệp tay (sáng 30/10 khoảng 25 phút, 2 lần sửa tay) | Kiểm chứng `talos-pinned` | ngoài repo |
| Sự cố OTel Collector sau cold start: cả 3 pod CrashLoop, không in dòng log nào, liveness kill sau 30 giây. `talosctl processes`: `otelcol-contrib` ở trạng thái D (chờ đĩa). Nguyên nhân: binary contrib khoảng 300 MB, page cache của nó tính vào limit 192Mi của container nên bị đọc lại từ HDD liên tục; trước reboot binary đã nằm sẵn trong page cache nên không lộ. Sửa: image `otel/opentelemetry-collector-k8s` (bản phân phối cho Kubernetes, đủ filelog/k8sattributes/otlphttp), limit 256Mi, `startupProbe` 5 phút. 11:08 3/3 Running, log về lại. Không có log từ 10:19 đến 11:08 | Bài học: image lớn + limit nhỏ + HDD = treo lúc cold start; chọn bản phân phối nhỏ nhất đủ dùng | `28ac69b`, `454c3d7` |
| demo-app access log (repo talos-demo-app `3c4a8ba`): mỗi request 1 dòng JSON qua slog (method, path, route, status, duration_ms, host, user_agent), mức ERROR khi 5xx; bỏ `/healthz`, `/readyz`, `/metrics`. Pipeline Jenkins #21 đạt, deploy `jenkins-sha-3c4a8ba` | namespace demo không có log trên dashboard "Log tập trung" vì app chỉ ghi 1 dòng lúc khởi động | `5713373` (tag do Jenkins ghi) |
| Rollout 11:22 bị huỷ lúc 11:38: Job ZAP (request 512Mi) Pending vì hết chỗ sau khi thêm log tập trung (w1 98%, w2 còn khoảng 360Mi), quá `activeDeadlineSeconds` 900. Bản cũ vẫn phục vụ. Hạ request ZAP xuống 320Mi (limit giữ 1Gi), `kubectl-argo-rollouts retry` 11:42, phân tích đạt, Healthy 11:47:48; log request của demo về VictoriaLogs | Đầu thu log lấy hết khoảng trống request; Job phân tích chỉ chạy vài phút mỗi lần deploy | commit này, commit hạ ZAP |
| Rà tài nguyên theo p95/max 7 ngày gộp theo container: request các thành phần đã khớp p95 + khoảng 15% (đặt 29/10), chỉ 3 chỗ dư: VictoriaLogs 192→96Mi (p95 43), harbor-postgres 128→80Mi (p95 53, max 129), harbor-portal 32→16Mi (max 4). Sau áp: w1 97%, w2 85%, cp1 36%. Không bớt RAM cp1 (kube-apiserver p95 khoảng 1,7 GB, MemAvailable thấp nhất 7 ngày 540 MB) | Hướng tiếp (chưa làm): giới hạn heap JVM Keycloak, chạy ZAP trên Jenkins, thêm RAM host2 (16 → 32 GB) | `1355680` |
| Dọn host2 (Hưng: "chỉ dùng để đăng nhập portal và làm trạm tài nguyên"): tắt gnome-remote-desktop hệ thống và phiên người dùng (RDP 3389/3390 đang mở ra LAN), mask cups (+socket/path), cups-browsed, avahi, ModemManager, apport; disable fwupd, colord, kerneloops, switcheroo, wpa_supplicant, motd-news, update-notifier timers; chặn evolution-* và update-notifier trong phiên người dùng; gỡ snap snap-store, firmware-updater; tắt mạng libvirt `default` (virbr0, 192.168.122.0/24). Giữ: libvirt/qemu, HAProxy, ssh, đường hầm GCP, timer backup/watchdog, gdm + Firefox, sysstat, unattended-upgrades. RAM khả dụng host2 khoảng 1,3 → 1,83 GB (thêm khoảng 0,6 GB nếu đóng Firefox sau khi đăng nhập portal). Cổng còn mở ra LAN: 22, 80, 443 | Giảm bề mặt tấn công và RAM thường trực của host | ngoài repo |
| Anh duyệt thêm worker w3 trên GCP (e2-standard-2, KubeSpan) cho tầng quan sát và job lúc deploy; kế hoạch `docs/ke-hoach-w3-gcp.md`, thi công dự kiến 03/11 | Cụm gần hết RAM, credit GCP còn khoảng 7,5 triệu đ đến 22/01/2027 | commit này |
| GCP budget "talos-lab free trial" 7.791.151 đ (24/10/2026–22/01/2027, tính chi phí trước khi trừ credit), báo mail ở 50/80/95% | Tài khoản Free Trial, thẻ của Phúc: không Upgrade, theo dõi mức tiêu | ngoài repo (GCP) |
| Bản sao backup thứ hai lên Google Cloud Storage: bucket `talos-kvm-offsite-gcs-vtc` (asia-southeast1, chặn công khai, tự xoá sau 30 ngày); service account `talos-backup-writer` chỉ có `roles/storage.objectCreator` trên bucket (không đọc/ghi đè/xoá được); `host2/bin/talos-offsite-gcs.sh` (JWT bằng openssl, không cần gcloud) + drop-in `35-gcs.conf` chạy sau B2 lúc 16:45; khoá ở `/etc/talos-offsite-gcs/sa.json` (root 600). Thử 13:23: bundle 10:06 lên GCS, md5 khớp | 2 nơi lưu trên 2 nhà cung cấp (B2 + GCS) | `075550b`, commit này |
| Image GCP `talos-v1-14-2` (Talos v1.14.2, Image Factory bản vanilla, platform gcp) sẵn cho w3; file tạm trên bucket đã xoá | Chuẩn bị thi công w3 ngày 03/11 | ngoài repo (GCP) |
| KubeSpan (tài liệu `KubeSpanConfig`, MTU 1380) bật trên cp1, w1, w2 13:44–13:53 bằng `talosctl patch --mode=no-reboot`, không node nào reboot; 6 cặp peer `up`; file `cp1/w1/w2.yaml` trên host2 đồng bộ (bak `*.bak-20261030-kubespan`) | Chuẩn bị nối worker GCP | ngoài repo (Talos) |
| **w3** (GCP e2-standard-2, Talos v1.14.2 image `talos-v1-14-2`, asia-southeast1-b, lịch `jenkins-office-hours`, không service account): firewall `talos-w3-kubespan` UDP 51820 và `talos-w3-apid` TCP 50000 chỉ từ 118.70.124.66/32; `apply-config --insecure` qua maintenance mode 13:55, Ready 13:57; taint `cloud=gcp:NoSchedule`, nhãn zone `gcp-asia-southeast1-b`. `w3.yaml` chỉ trên host2 | Anh duyệt 30/10, kế hoạch `docs/ke-hoach-w3-gcp.md` | ngoài repo (GCP, Talos) |
| Xử lý mạng w3: (1) DNS UDP từ w3 timeout, `flannel.1` bật `tx-checksum-ip-generic`: thêm `EthernetConfig` `flannel.1` tắt offload trên cả 4 node (giữ qua reboot, đã reboot w3 kiểm); (2) vẫn mất gói từng đợt 20–65% w3↔w2: bắt gói 3 điểm (eth0 w3, uplink host2, vnet w2) thấy w3 gửi nhầm tới IP nội bộ `10.10.10.22:51820`; danh sách endpoint của w3 chỉ có cổng 51820 trong khi NAT công ty đổi cổng (57995/36279/43095), mỗi lần Talos cấu hình lại WireGuard thì endpoint về danh sách sai đến khi roaming học lại. Sửa: `harvestExtraEndpoints: true` trên 4 node → endpoint thật có trong danh sách, gói gửi nhầm 26/phút → 1/5 phút, mất gói còn 0–7%/phút, đo 5 phút lúc 15:33: trong đường hầm 0,83%, Internet trần host2 → w3 1,17%, host2 → 8.8.8.8 0,83% (mất gói của đường Internet công ty, không do KubeSpan). NAT host2 ổn định (đã kiểm bằng `conntrack`, cài thêm gói `conntrack`) | Bài học: KubeSpan qua 2 lớp NAT cần harvestExtraEndpoints; kiểm từng lớp (WireGuard thuần qua IPv6 KubeSpan, Flannel qua IP pod) | ngoài repo (Talos) |
| VictoriaLogs chuyển lên w3 (toleration `cloud`, nodeAffinity w3, PVC mới; log trước khi chuyển nằm trên PV cũ ở w2); toleration `cloud` cho helper local-path và OTel Collector | Giảm tải w2; giai đoạn 4 kế hoạch w3 | commit này |
| Prometheus chuyển từ w1 lên w3 (toleration `cloud`, nodeAffinity w3, PVC mới: mất số đo 7 ngày trước, PV cũ giữ trên w1). Alertmanager ở lại w2 (cần DNS UDP tới Telegram). w3 tắt 17:15 theo lịch: để cụm chạy qua đêm thì tạm dừng watchdog | w1 97% request; Prometheus scrape theo IP, lấy target qua API (TCP) | commit này |
| Job ZAP (AnalysisTemplate `demo-app-zap-baseline`) ưu tiên w3 (preferred, w3 tắt thì về on-prem), toleration `cloud`, `dnsConfig` `use-vc` (DNS qua TCP vì UDP từ w3 còn mất vài %). Sau khi chuyển: w1 78%, w2 83%, w3 14% request; Prometheus 42/42 target up | Rollout 30/10 sáng bị huỷ vì ZAP không có chỗ | commit này |
| App `image-scan`: CronJob Trivy 0.76.1 (12:30 T2–T6, ưu tiên w3, ns demo dùng `ghcr-pull`) quét mọi image đang chạy, CVE CRITICAL có bản vá thì Job fail và cảnh báo `ImageScanCritical` về Telegram; kết quả từng image là dòng `SCAN` trong log tập trung. Đóng firewall GCP: xoá `default-allow-rdp`, `default-allow-ssh` chỉ còn IP công ty | Lấp khoảng trống anh hỏi 29/10: image chỉ được quét lúc build; SSH/RDP đang mở ra Internet | commit này |
| Ưu tiên w3 (preferred, w3 tắt thì về on-prem): kube-state-metrics, prometheus-operator, Argo CD repo-server và applicationset-controller (Argo CD helm rev 9, thêm `dnsConfig use-vc`). Headlamp ở lại vì OIDC server-side cần `keycloak.talos.internal` | Bớt pod tranh HDD lúc cold start, bớt khoảng 600Mi request on-prem; đánh đổi: mất Internet thì Argo CD tạm không sync | commit này |
| Ưu tiên w3 thêm: argo-rollouts, Alertmanager (`use-vc`), sealed-secrets-controller. Quét image thủ công 30/10: 49 image, 15 có CVE CRITICAL đã có bản vá (7 image Harbor nền Photon, nginx-unprivileged 1.27.3, curl 8.11.1, postgres 18.6, argocd, k8s-sidecar, flannel, chính trivy/python); demo-app, Keycloak, Vault, Traefik, Prometheus, Grafana sạch | Bớt request w2; chuyển Alertmanager cạnh Prometheus vì mất Internet thì Telegram cũng không gửi được | commit này |
| Đo cold start 16:03:29 với w3 (bật 3 VM on-prem cùng lúc, w3 vẫn chạy): API chậm nhất +1:37, Harbor +6:40, demo-app 2/2 +9:26 (10:19: +4:20, +9:13, +10:48), PSI đỉnh 32%, không can thiệp tay. Còn lại: oauth2-proxy CrashLoop vì lên trước Keycloak (backoff, tự hết); w2 nhận hết pod (99%, w1 38%) vì Ready trước, Collector trên w2 Pending. Sửa: Collector `priorityClassName: system-node-critical` | Kiểm chứng cấu hình có w3; việc tiếp: bật VM lệch nhau hoặc topologySpreadConstraints | commit này |

## 29/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Viết lại `docs/kien-truc.md` theo hiện trạng: 1 control plane, Jenkins deploy, Harbor, Kyverno, Vault, SSO Keycloak | Sơ đồ cũ (16/10) không còn đúng | `b608ba2` |
| Bổ sung nhật ký 20/10 – 28/10; viết lại `docs/bao-cao.md`, `docs/truy-cap.md` và `README.md` theo hiện trạng | Tài liệu cho anh hướng dẫn theo dõi không còn khoảng trống | `5099d39`, `d9d7d07`, commit README |
| Sự cố khởi động lạnh 08:37: PSI io full khoảng 33%, etcd chậm, API mất khoảng 1 phút, controller-manager và scheduler restart; tự hồi phục | Ghi nhận (gốc HDD), xem `bao-cao.md` mục 5 | ngoài repo |
| Sự cố 08:47–09:11: Keycloak bị startup probe kill sau 20 phút (bước build Quarkus chậm vì IO); w2 nhận gần hết pod (request RAM 88%), Talos OOM-kill 2 lần (08:58, 09:05), Grafana restart liên tục. Xử lý: xoá pod `keycloak-0` để nó sang w1; 09:11 cụm sạch, request RAM w1 39% / w2 69%. Khởi động lạnh hôm nay khoảng 50 phút | Ghi nhận; sửa gốc: request RAM sát mức dùng thật, Keycloak image optimized | ngoài repo (xoá pod tay) |
| Request RAM nâng lên khoảng p95 working set 7 ngày (+15%): Prometheus 400→704Mi, Grafana 384→704Mi, Vault 128→256Mi, Traefik 64→224Mi (x2), cert-manager, External Secrets, Kyverno, Argo Rollouts, prometheus-operator, kube-state-metrics, Alertmanager, Headlamp, Sealed Secrets, local-path. Tổng request trên 2 worker từ khoảng 4,2 lên 5,7 GiB / 7,8 GiB allocatable | Request thấp hơn mức dùng thật (tổng p95 cao hơn tổng request) làm scheduler xếp quá tải w2 lúc khởi động lạnh, gây OOM 29/10. Đánh đổi: khi chỉ còn 1 worker, một số pod sẽ Pending thay vì chạy rồi bị OOM | `c3cd6ab` |
| User Keycloak `mentor_view` (realm talos, nhóm talos-viewers, chỉ xem) bằng script mới `platform/keycloak/add-user.sh` (mật khẩu tạm ngẫu nhiên, bắt đổi lần đầu) | Anh hướng dẫn cần tài khoản chỉ xem | ngoài repo (Keycloak) + commit này |
| Jenkins, GitLab, SonarQube có link trong LAN: host2 giữ đường hầm SSH tới GCP (`host2/systemd/gcp-tunnel-*.service`, khóa riêng chỉ mở đúng cổng, `command="/bin/false"`), app `gcp-tools`: pod nginx chuyển tiếp tới 10.10.10.1 (Argo CD không quản lý EndpointSlice) + Ingress `jenkins/gitlab/sonarqube.talos.internal` (CA nội bộ). Không mở cổng nào trên GCP | Anh hướng dẫn cần link; chọn chỉ trong LAN vì Jenkins không nên lộ ra Internet | commit này |
| Đổi URL gốc sang link mới: Jenkins URL `https://jenkins.talos.internal/`, GitLab `external_url` (nginx giữ HTTP :18081, tắt Let's Encrypt; `gcp/gitlab-set-url.sh`), SonarQube Server base URL; 3 client SAML trên Keycloak nhận cả URL mới và URL localhost cũ. Duyệt `mentor_view` trên GitLab (External, Reporter project talos-demo-app) | Đăng nhập SAML trả về đúng link mới; đã thử đăng nhập cả 3 | ngoài repo (GCP) + `25367a0`, commit này |
| Bộ sơ đồ kiến trúc mới bằng D2, có logo công cụ (`docs/so-do/`): 6 hình riêng (bối cảnh, hạ tầng vật lý, thành phần trong cụm, luồng deploy, luồng backup, phụ thuộc bên ngoài); thay sơ đồ Mermaid ở mục 1 và 2 của `kien-truc.md` | Anh hướng dẫn nhận xét sơ đồ cũ quá đơn giản; sơ đồ cũ gộp nhiều loại kiến trúc vào một hình | commit này |
| Request RAM cho sidecar Grafana (96Mi), init-chown-data (16Mi), config-reloader (48Mi); ValidatingAdmissionPolicy require-memory-request (mọi container phải có requests.memory, trừ kube-system), chế độ Warn + Audit, app Argo CD thứ 19 admission-policies | Chặn đúng loại lỗi gây OOM sáng 29/10; dùng policy gốc của Kubernetes (không webhook) để không phụ thuộc Kyverno. Chuyển Deny khi không còn cảnh báo | 385273e, abc7c3b |
| Argo CD (Helm bootstrap, revision 7 -> 8): request RAM controller 512->768Mi, server 64->224Mi, repo-server 128->176Mi, applicationSet 64->112Mi, redis 32->80Mi theo p95 7 ngày; áp bằng helm upgrade tay | Cùng lý do với commit c3cd6ab; Argo CD không tự quản lý chính nó | 9d97f2a |
| Image Keycloak "optimized": `platform/keycloak/image/Dockerfile` (chạy `kc.sh build` lúc build image) + workflow GitHub Actions đẩy `ghcr.io/hungkobe273/talos-keycloak` (Trivy báo cáo). Chưa đổi Keycloak đang chạy | Bỏ bước build Quarkus 5–12 phút mỗi lần Keycloak khởi động (sự cố 29/10) | `71de393` |
| Replication Harbor `ghcr-keycloak` (mỗi giờ); SealedSecret `keycloak/harbor-pull`; Keycloak chạy `harbor.talos.internal/talos/talos-keycloak:26.8.1-71de393` với `start --optimized --import-realm`. Lùi: image `quay.io/keycloak/keycloak:26.8.1`, bỏ `--optimized` | Keycloak khởi động không còn bước build; image kéo từ Harbor nội bộ | `27c4be6`, commit này |
| Diễn tập khôi phục Vault (Phúc, Hưng): ns tạm `vault-drill`, Vault 2.0.4 cùng seal GCP KMS trên w1, restore `vault-2026-10-28-101053.snap`, tự unseal, đọc được `kv/demo/demo-app` (chỉ tên key); lần chạy sạch khoảng 2,5 phút; đã xoá ns tạm, Vault thật không restart. Gặp: snapshot mang audit device `file/`, nơi khôi phục thiếu `/vault/audit` ghi được thì Vault tự seal; timer backup `Persistent=false` nên ngày tắt host2 trước 16:45 không có snapshot | Chứng minh backup Vault dùng được; ghi lại điều kiện khôi phục | ngoài repo |

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
