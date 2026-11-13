# Kiến trúc cụm talos-kvm

Người thực hiện: Hưng, Phúc. Cập nhật: 06/11/2026.

Cụm Kubernetes on-premise trên một máy KVM (kvm-host2), thêm một worker trên Google Cloud nối bằng KubeSpan, vận hành theo GitOps. Code đi từ GitHub qua Jenkins, được quét và ký, rồi Argo CD triển khai blue-green. Cụm kéo image của ứng dụng thẳng từ GHCR và chỉ chạy image có chữ ký của Jenkins (Harbor nội bộ đã bỏ 09/11).

Khi có thay đổi hạ tầng hoặc cấu hình, sửa file này cùng commit và ghi thêm vào [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md).

## 1. Bộ sơ đồ

Sáu hình, đọc từ tổng quát đến chi tiết; mỗi hình trả lời một câu hỏi. Màu theo nhóm: xanh ngọc là nền tảng, cam là bảo mật, xanh lá là ứng dụng, xanh dương là danh tính, tím là giám sát; khung nét đứt là dịch vụ bên ngoài. Trong các hình luồng, nét xanh chuyển động chỉ hướng dữ liệu, nét cam đứt là Kyverno kiểm chữ ký.

### 1.1 Bối cảnh: hệ thống nói chuyện với ai

![Bối cảnh](so-do/boi-canh.svg)

### 1.2 Hạ tầng vật lý: cái gì chạy trên máy nào

![Hạ tầng vật lý](so-do/ha-tang.svg)

Ba VM Talos on-prem dùng chung một ổ HDD của host2 (nút thắt IO: lúc khởi động lạnh 03/11, CPU chờ đĩa 43–64% thời gian). w3 trên GCP có đĩa riêng. Volume dùng local-path nên pod có dữ liệu bị ghim vào đúng một worker. Từ 05/11 tới 09/11 có thêm StorageClass `nfs-host2` (đã gỡ cùng Harbor 09/11): PV nằm trên NFS server của host2 (`/srv/nfs/k8s`, ngoài các VM), mount được từ w1 và w2; Harbor registry (image, chữ ký) chạy trên `nfs-host2` từ 05/11. Test Postgres T1–T8 đạt (pod chuyển node giữ dữ liệu, sập khi ghi tự phục hồi, mất NFS 60 s chỉ treo), nhưng fsync qua NFS chậm gấp 4, nên DB (Harbor postgres, Vault) cùng Grafana, Prometheus, VictoriaLogs vẫn dùng local-path. Anh góp ý 05/11: NFS là một server đơn, không HA. Từ 06/11 có **Longhorn** (StorageClass `longhorn`): mỗi worker w1, w2 có thêm đĩa qcow2 20G `vdb` dành riêng, mỗi PV giữ 2 bản sao trên 2 worker. Test L1–L6: rút điện một worker thì Postgres tự lên ở worker kia sau 4:45 với đủ dữ liệu, sập giữa lúc ghi vẫn toàn vẹn, fdatasync 4,7 ms (NFS 51 ms), Velero backup/khôi phục được dữ liệu volume. Giới hạn: 2 bản sao vẫn cùng ổ HDD của host2, chống mất một node chứ không chống mất host2; và khi mất một worker, worker còn lại chưa chạy được hết pod (memory request w1 69%, w2 67% sau khi bỏ Harbor). Grafana (SQLite) chạy trên Longhorn từ 06/11 (`grafana-longhorn`), Vault từ 10/11 (`data-vault-0`, `audit-vault-0`): w1, w2 không còn PV local-path nào. Harbor và NFS gỡ 09/11. Thử I/O scheduler BFQ trên host2 10/11 để ưu tiên đĩa cho cp1: etcd chậm hơn, đã lùi về mq-deadline (`docs/de-xuat-bfq.md`).

### 1.3 Thành phần trong cụm: ai gọi ai

![Thành phần trong cụm](so-do/thanh-phan.svg)

### 1.4 Luồng đưa code lên production

![Luồng deploy](so-do/luong-deploy.svg)

### 1.5 Backup hằng ngày

![Luồng backup](so-do/luong-backup.svg)

### 1.6 Phụ thuộc bên ngoài

![Phụ thuộc bên ngoài](so-do/phu-thuoc.svg)

Nguồn các hình là file text D2 trong [so-do/](so-do/) (`chung.d2` chứa màu và kiểu dùng chung). Sửa xong thì xuất lại, ví dụ `d2 docs/so-do/ha-tang.d2 docs/so-do/ha-tang.svg`. Logo lấy từ CNCF artwork và Simple Icons, được nhúng thẳng vào SVG.

## 2. Hạ tầng

Sơ đồ: mục 1.2.


| VM | IP | vCPU | RAM | Tên node | Ghi chú |
|---|---|---|---|---|---|
| cp1 | 10.10.10.11 | 2 | 4 GB (3,5 GB tới 12/11) | talos-w9b-tsv | control plane duy nhất từ 20/10 |
| w1 | 10.10.10.21 | 2 | 4 GB (4,5 GB tới 12/11) | talos-hdl-7jo | thường chạy Keycloak, Vault, Kyverno, argocd-server (không ghim); đĩa thứ hai `vdb` 20G cho Longhorn |
| w2 | 10.10.10.22 | 2 | 4,5 GB | talos-iv6-z5m | thường chạy Grafana (Longhorn, không ghim); đĩa thứ hai `vdb` 20G cho Longhorn |
| w3 (GCP) | 10.148.0.4 | 2 | 8 GB | w3 | VM GCP e2-standard-2 (asia-southeast1-b), nối cụm bằng KubeSpan (WireGuard) từ 30/10; taint `cloud=gcp:NoSchedule`; ghim Prometheus, VictoriaLogs; ưu tiên (preferred) Alertmanager, argo-rollouts, sealed-secrets, kube-state-metrics, prometheus-operator, Argo CD repo-server, applicationset, application-controller và redis (controller, redis từ 06/11, `helm` rev 11), job ZAP, job image-scan; không đặt thứ cần `*.talos.internal` lên đây; bật 08:15–17:15 T2–T6, T2/T4 tắt lúc 10:40 (job `w3-stop-mon-wed`, 11:30 tới 10/11) |
| cp2, cp3 | .12, .13 | | | | tắt, giữ đĩa để bật lại khi cần HA |

- Node chạy Talos Linux, không có SSH, quản trị bằng API `talosctl`.
- Dịch vụ truy cập qua HAProxy :443 trên host2 rồi vào Traefik. Tên miền `*.talos.internal`, chứng chỉ do CA nội bộ (cert-manager) cấp. Laptop cần thêm tên vào file hosts ([truy-cap.md](truy-cap.md)).
- Host2 ra Internet qua captive portal của văn phòng. Host2 bị tắt cuối ngày (T2/T4 lúc 10:30); bật/tắt cụm theo runbook.

## 3. Luồng đưa code lên production

1. **Push code** lên GitHub (talos-demo-app). Jenkins kiểm tra repo 5 phút một lần.
2. **Jenkins quét, build và ký**: gitleaks quét toàn bộ lịch sử Git, test có coverage, govulncheck, gosec, quality gate SonarQube; build image amd64 + arm64, đẩy lên GHCR một lần; Trivy quét đúng digest vừa đẩy; SBOM CycloneDX; ký cosign. Cổng nào lỗi thì dừng, không có image được ký.
3. **Jenkins sửa `newTag`** trong `apps/demo-app/kustomization.yaml` của repo này và push.
4. **Argo CD đồng bộ** commit mới vào Rollout của demo-app. Mọi thay đổi trong cụm đi qua Git; sửa tay sẽ bị self-heal đưa về.
5. **Blue-green**: pod preview kéo image thẳng từ `ghcr.io/hungkobe273/talos-demo-app` (từ 09/11; trước đó qua bản sao Harbor, chờ replicate 10 phút); Kyverno từ chối nếu image không có chữ ký của Jenkins. Preview phải qua smoke test, phân tích tỉ lệ lỗi và quét ZAP rồi mới nhận traffic. Bản cũ giữ thêm 10 phút để quay lại nhanh.

Đo ngày 28/10: từ lúc push tới lúc bản mới nhận traffic khoảng 12 phút (pipeline khoảng 6 phút, blue-green khoảng 6 phút). Kéo image từ Harbor 5 đến 7 giây (Harbor đã bỏ 09/11, nay kéo từ GHCR, bỏ được khoảng chờ replicate).

GitHub Actions và GitLab CE vẫn build cùng app để so sánh, nhưng chỉ tạo image `sha-*` không ký và không deploy.

## 4. Thành phần trong cụm

25 ứng dụng Argo CD theo mô hình app-of-apps: `bootstrap/root.yaml` apply tay một lần, app `root` quản lý các app còn lại trong `argocd-apps/`.

| Nhóm | App Argo CD | Chart / phiên bản | Vai trò |
|---|---|---|---|
| Nền tảng | root | | app-of-apps |
| | traefik | traefik 42.0.0 | ingress |
| | cert-manager, cert-manager-issuers | cert-manager v1.21.2 | chứng chỉ từ CA nội bộ `talos-internal-ca` |
| | sealed-secrets | 2.20.0 | secret mã hóa nằm trong Git |
| | local-path | | lưu trữ trên đĩa worker |
| | longhorn | longhorn 1.13.0 | StorageClass `longhorn`: mỗi PV 2 bản sao trên w1 và w2 (đĩa riêng `vdb` 20G mỗi worker), node chết thì pod lên worker kia với đúng dữ liệu (từ 06/11, theo góp ý NFS không HA) |
| | descheduler | 0.37.0 | cân bằng lại pod giữa w1 và w2 |
| | argo-rollouts | 2.43.8 | blue-green và phân tích |
| | admission-policies | | PriorityClass `talos-core` (2000, từ 06/11: Traefik, Keycloak, Kyverno, cert-manager, External Secrets, Vault) và `talos-pinned` (1000, pod bị ghim); ValidatingAdmissionPolicy `require-memory-request` (Deny + Audit từ 05/11) |
| | gcp-tools | | pod nginx `tunnel-proxy` và Ingress cho Jenkins, GitLab, SonarQube trên GCP (qua tunnel SSH của host2) |
| Bảo mật | kyverno | 3.9.2 (Kyverno 1.19.2, từ 12/11) | ImageValidatingPolicy: chỉ nhận image ký bằng khoá Jenkins, webhook chỉ ở ns demo |
| | vault | 0.34.1 (Vault 2.0) | secret của ứng dụng, tự unseal bằng GCP KMS, audit log |
| | external-secrets | 2.14.0 | đưa secret từ Vault vào Secret của pod |
| | image-scan | | CronJob Trivy 12:30 T2–T6 quét mọi image đang chạy, alert `ImageScanCritical` khi có CVE CRITICAL |
| Danh tính | keycloak | keycloakx 7.4.0 | SSO OIDC/SAML, DB trên Supabase |
| | oauth2-proxy | | đăng nhập Keycloak trước Prometheus, Alertmanager, vmui của VictoriaLogs (`logs.talos.internal`, chỉ mở `/select`) |
| | headlamp | 0.45.0 | giao diện cụm |
| Giám sát | monitoring | kube-prometheus-stack 92.2.0 | Prometheus, Alertmanager, Grafana |
| Log tập trung | victoria-logs | victoria-logs-single 0.13.10 | lưu log 7 ngày (tối đa 4 GiB), tra cứu bằng vmui `https://logs.talos.internal/select/vmui/` (LogsQL, theo trường, từ 05/11, anh duyệt); Grafana dashboard "Log tập trung" chỉ để theo dõi (số dòng theo pod, dòng có chữ error) |
| | otel-collector | opentelemetry-collector 0.176.0 | DaemonSet trên cả 4 node, đọc `/var/log/pods`, gắn namespace/pod/container, đẩy OTLP về VictoriaLogs; từ 05/11 tách log JSON thành trường ngay lúc thu (processor `transform/parse`, namespace `demo`, `argocd`), `level` thành severity |
| Backup | velero | velero 12.2.2 (Velero v1.18.4, plugin GCP v1.14.4) | backup object Kubernetes lên bucket GCS `talos-kvm-velero-vtc` 09:30 T2–T6, giữ 30 ngày; ưu tiên chạy trên w3. node-agent (backup dữ liệu PV Longhorn theo file, kopia) có từ 06/11, **tắt từ 10/11** vì không backup nào dùng mà mỗi lần khởi động đọc khoảng 215 MB từ HDD; dữ liệu Vault đã nằm trong gói backup 16:45, Grafana dựng lại từ Git. Cần thì bật tạm `deployNodeAgent` |
| Ứng dụng | demo-app | | app Go mẫu, Rollout blue-green |

Talos v1.14.2, Kubernetes v1.37.1, CNI Flannel.

## 5. Bảo mật

- **Chuỗi cung ứng**: mọi cổng của Jenkins đã thử bằng commit hoặc image lỗi cố ý. Image không ký bị Kyverno từ chối (Kyverno đọc chữ ký trên GHCR). Khoá công khai cosign ở `platform/cosign/cosign.pub`. Image đang chạy được quét lại mỗi ngày làm việc (app `image-scan`); 02/11 còn 11/48 image có CVE CRITICAL, phân tích ở `TTS_QTDV/design/cve-con-lai-02-11.md`.
- **Secret**: hạ tầng dùng Sealed Secrets. Biến môi trường của ứng dụng nằm ở Vault (`kv/demo/demo-app`), External Secrets đưa vào pod; đổi giá trị không cần commit.
- **Đăng nhập**: Keycloak SSO cho Grafana, Argo CD, Headlamp, Vault, Jenkins, GitLab, SonarQube, và Prometheus, Alertmanager, vmui của VictoriaLogs qua oauth2-proxy. Quyền theo nhóm `talos-admins`, `talos-viewers`. Mỗi công cụ giữ một tài khoản dự phòng khi Keycloak hỏng.
- **Mạng**: dịch vụ chỉ mở trong LAN qua HAProxy. w3 nối cụm bằng WireGuard (KubeSpan); firewall GCP chỉ mở UDP 51820 và API Talos cho IP công ty.
- **SSH vào host2** (từ 13/11, `host2/ssh/`): cấm root, tắt keyboard-interactive; từ mạng VM `10.10.10.0/24` và mạng pod `10.244.0.0/16` không ai đăng nhập được (`DenyUsers *`), nên pod bị chiếm không SSH ngược lên host2. Mật khẩu vẫn mở cho tới khi mọi máy cần vào đã có khoá (giai đoạn B, `20-no-password.conf`). rpcbind (cổng 111) đã `mask`, host2 không dùng NFS.

## 6. Vận hành

- **Backup** hằng ngày 16:45 trên host2 (ngoài cụm): snapshot etcd, dump DB Keycloak (Supabase), snapshot Vault (dump DB Harbor tới 09/11); gom thành một gói mã hóa GPG, đẩy lên Backblaze B2 và Google Cloud Storage (từ 30/10; tài khoản ghi lên GCS chỉ thêm được, không xoá được). Lỗi bước nào thì báo Telegram. Đã thử giải mã gói backup; đã diễn tập khôi phục Vault (29/10; 10/11 lại trên Longhorn: 59 s từ snapshot tới đọc được secret) và **toàn cụm lên GCP (05/11): RTO chính 51 phút (demo-app trả 200 từ cụm mới), RTO đầy đủ 54 phút, RPO 6–7 phút**; ước lượng chạy sạch khoảng 40 phút. Từ 03/11 thêm Velero backup object Kubernetes lên GCS (bucket riêng, chặn public, SA chỉ có quyền với object của bucket này); dữ liệu PV local-path vẫn lấy từ gói hằng ngày; từ 06/11 Velero có node-agent để backup dữ liệu PV Longhorn theo file khi cần.
- **Cảnh báo**: Prometheus/Alertmanager báo Telegram khi cụm còn sống (demo-app, ExternalSecret, Keycloak, `VaultNotReady`, `ImageScanCritical`, `VeleroBackupFailed`, `VeleroNoRecentBackup`; từ 10/11 Longhorn: `LonghornVolumeFaulted` 5 phút, `LonghornVolumeDegraded` 20 phút, `LonghornNodeNotReady`, `LonghornDiskAlmostFull` > 80%). Watchdog trên host2 (`host2/bin/talos-watchdog.sh`) và healthchecks.io báo khi cả cụm chết; từ 05/11 watchdog kiểm dung lượng đĩa (09/11 bỏ kiểm `nfs-server` khi gỡ NFS, nay đo `/var/lib/libvirt/images`); từ 06/11 watchdog gắn taint `node.kubernetes.io/out-of-service` khi VM worker đã tắt hẳn và node không Ready (để StatefulSet như Keycloak chuyển được node), gỡ khi VM chạy lại; từ 10/11 `eso_kick`: Vault đã Ready mà ClusterSecretStore hoặc ExternalSecret còn lỗi thì annotate để External Secrets thử lại ngay, mỗi lần watchdog chạy (3 phút) (ESO tự lùi thời gian thử lại tới khoảng 16 phút sau mỗi lần Vault dừng).
- **Log tập trung** (30/10): OpenTelemetry Collector thu log mọi pod, đẩy về VictoriaLogs; tra cứu bằng vmui sau oauth2-proxy (`talos-admins`, `talos-viewers`); Grafana chỉ giữ dashboard theo dõi và datasource cho cảnh báo từ log. Chọn VictoriaLogs thay SigNoz vì SigNoz tự host không có SSO và cần ClickHouse 2–4 GiB RAM; đầu thu là OTLP chuẩn nên đổi backend chỉ cần đổi exporter. Từ 05/11 (anh góp ý tra theo trường như ELK): log JSON (demo-app, Argo CD, Keycloak) được tách thành trường lúc thu, `level` đổi thành `severity_text` chuẩn, tra theo trường và hàm tổng hợp, ví dụ `route:* | stats by (status) count()`; vmui cho tra tự do.
- **Khởi động lạnh**: đo lại 06/11 sau khi có Longhorn: dịch vụ chính (demo, Harbor, Keycloak) lên trong khoảng 6–6,5 phút; 09/11 cold start thật (tính cả lúc host2 boot) Keycloak +7:42, Grafana +10:51, Grafana (trên Longhorn, chờ Longhorn khởi động) khoảng 9 phút; cụm đọc khoảng 8,4 GB từ HDD lúc khởi động. 10/11 sáng (sau khi bỏ Harbor): xanh khoảng +9:00, Grafana +8:55; 12/11 cold start thật (CSI 1 bản): Keycloak +6:37, Vault +7:14, Grafana +7:57. 10/11 09:51 thử sau khi Vault sang Longhorn (chỉ tắt bật VM): Keycloak +5:44, Vault +6:52 (chờ Longhorn gắn lại volume, chậm hơn local-path khoảng 1 phút), Grafana +8:14, xanh +8:33. `coldstart-watch` trên host2 ghi các mốc mỗi lần host2 boot (`~/talos-kvm/coldstart-logs/`). Trước Longhorn: khoảng 6 phút (5:59, đo 03/11 13:16) từ lúc bật VM tới khi mọi app Healthy, không can thiệp tay, có khởi động lại host2; trước các bản sửa ngày 03/11 là khoảng 11 phút. Keycloak có sidecar `prefetch` đọc tuần tự jar vào page cache nên JVM khởi động 25–29 giây thay vì 98–111 giây; Grafana tắt 16 plugin không dùng. Nút thắt vẫn là ổ HDD: lúc khởi động cụm đọc khoảng 5,5 GB, ba pod về cuối (Keycloak, harbor-jobservice, Grafana) chỉ cách nhau 11 giây. Tắt cụm bằng `talosctl shutdown --force`, control plane trước rồi worker, để pod giữ nguyên node (từ 03/11, xem nhật ký). **Từ 10/11 tắt bằng `host2/bin/talos-cluster-stop.sh`**: tạm dừng Argo CD cho app có volume Longhorn (`monitoring`, `vault`, annotation `skip-reconcile`), thu Grafana và Vault về 0, chờ volume `detached` rồi mới tắt cp1, w1, w2; lúc host2 boot `talos-cluster-resume.service` chờ instance-manager Longhorn trên w1, w2 Ready rồi trả replicas và trả app cho Argo CD. Volume không còn `faulted` và không dựng lại bản sao (instance-manager đọc khoảng 0,42 GB thay vì 1,55 GB). Cold start thật 10/11 11:35 (tính từ libvirtd): API +1:55, Keycloak +6:26, **Vault +6:49, store Vault Valid +7:19, Grafana +8:01**, cả cụm xanh trước +10:30; lần 10:22 (tắt kiểu cũ, volume faulted) là Vault +7:11, Grafana +9:17.
- **Mất một worker** (test 06/11, rút điện w1): Longhorn giữ dữ liệu (2 bản sao), watchdog gắn taint `out-of-service`, các pod `talos-core` đẩy pod ưu tiên thấp (Grafana, Argo CD UI, Headlamp...) để chạy trên worker còn lại: Keycloak trả lời lại sau khoảng 5,5 phút, Harbor và demo không gián đoạn. Giới hạn: RAM dùng thật của 2 worker (khoảng 4,5 GiB) lớn hơn một worker (3,9 GiB) nên không chạy được hết app. Test lại 10/11 13:49 sau khi Vault sang Longhorn và CSI sidecar còn 1 bản (rút điện w1, nơi có vault-0, keycloak-0 và csi-attacher): taint +1:55, csi-attacher lên ở w2 +2:39, **Vault Ready trên w2 +3:34, store Vault Valid +3:35, Keycloak +3:46**, demo-app luôn còn 1 pod Ready; Grafana bị đẩy ra (Pending) tới khi w1 về. Bật lại w1: taint gỡ +1:15, 3 volume dựng lại bản sao và `healthy` sau +4:26, Grafana +5:53. Ổ HDD chung có lúc làm etcd trượt health check, Talos gỡ VIP khoảng 25 s.
- **Tầng GCP bằng Terraform** (`infra/gcp`, từ 06/11): 40 tài nguyên (3 VM, 2 IP, image, 5 firewall, lịch bật/tắt và snapshot, job Scheduler, 3 bucket, 4 SA, 2 custom role, 5 quyền IAM, KMS, Cloud SQL, 9 API) đã import vào state ở bucket `talos-kvm-tfstate-vtc` (versioning), `plan` báo `No changes`. Từ 10/11 T2/T4 tắt cả w3, `jenkins-1`, `gitlab-1` lúc 10:40 (3 job Cloud Scheduler `*-stop-mon-wed`, SA `w3-stopper`), các ngày khác 08:15–17:15; chi phí ước khoảng 62 USD/tháng, chi tiết `docs/de-xuat-giam-chi-phi-gcp.md`. Sửa hạ tầng GCP qua Terraform, không sửa tay trên Console.
- **Runbook**: bật/tắt hằng ngày, kiểm tra backup, xử lý các lỗi đã gặp (ngoài repo, file `talos-kvm-runbook.md`).

## 7. Giới hạn đã biết

- Một ổ HDD dùng chung cho etcd, Prometheus và kéo image: IO là giới hạn chính.
- Chỉ 1 control plane để tiết kiệm RAM: mất cp1 thì mất API cho tới khi bật lại.
- Phụ thuộc Internet qua captive portal: mất mạng thì Vault không unseal (cần KMS), Keycloak không vào được DB (Supabase), Argo CD không đọc được Git, w3 rời cụm (mất Prometheus, log). Tunnel tới GCP có `ConnectTimeout` để tự nối lại khi đăng nhập portal muộn.
- w3 không tới được `*.talos.internal` và host2: thứ cần Keycloak phải chạy on-prem. Pod trên w3 dùng DNS qua TCP vì UDP qua đường hầm mất khoảng 1% gói.
- Volume local-path còn lại (Prometheus, VictoriaLogs trên w3) ghim vào một node: node đó tắt thì dịch vụ đó ngừng. Vault và Grafana đã trên Longhorn (10/11, 06/11).
- Tắt cụm bằng lệnh tay (không qua `talos-cluster-stop.sh`) hoặc mất điện khi volume Longhorn còn gắn: lúc bật lại Longhorn đánh dấu volume `faulted`, dựng lại bản sao (đọc thêm khoảng 1,1 GB), Vault và Grafana chờ thêm 1–2 phút. App mới có PVC Longhorn phải thêm vào danh sách `WORKLOADS` của script. Từ 12/11 script kiểm trước: 30 phút gần nhất chưa có backup thành công thì tự chạy backup, lỗi thì không tắt.
- Resume phải chờ instance-manager Longhorn trên cả w1 và w2 (khoảng +5:50) thì Vault, Grafana mới được bật; đây là phần lớn thời gian chờ của hai app này.
