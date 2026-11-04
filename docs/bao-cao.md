# Báo cáo hiện trạng cụm talos-kvm

Người thực hiện: Hưng, Phúc. Cập nhật: 03/11/2026.

File này là báo cáo tổng hợp, cập nhật mỗi khi có thay đổi lớn. Chi tiết từng thay đổi theo ngày ở [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md); sơ đồ và thành phần ở [kien-truc.md](kien-truc.md); cách vào các giao diện ở [truy-cap.md](truy-cap.md).

## Tóm tắt

- Cụm Talos 1 control plane + 2 worker trên một máy KVM (kvm-host2 `192.168.136.38`), API qua VIP `10.10.10.100:6443`, thêm worker w3 trên Google Cloud nối bằng KubeSpan từ 30/10 (chạy Prometheus, VictoriaLogs và các bộ điều khiển). cp2, cp3 đã tắt từ 20/10 để tiết kiệm RAM và IO.
- GitOps bằng Argo CD (24 app). Jenkins trên Google Cloud là deployer: quét bảo mật, build, ký image, rồi sửa tag trong repo này. Argo Rollouts triển khai blue-green có smoke test, phân tích tỉ lệ lỗi và quét ZAP.
- Cụm kéo image từ Harbor nội bộ; Kyverno chỉ cho chạy image có chữ ký của Jenkins. Secret của ứng dụng nằm ở Vault. Đăng nhập tập trung bằng Keycloak cho 10 công cụ.
- Giám sát và cảnh báo về Telegram, log tập trung (OpenTelemetry, VictoriaLogs), quét CVE image đang chạy mỗi ngày làm việc, watchdog ngoài cụm. Backup hằng ngày mã hóa lên Backblaze B2 và Google Cloud Storage; từ 03/11 thêm Velero backup object Kubernetes.
- Nút thắt lớn nhất vẫn là ổ HDD duy nhất: sáng 03/11 lúc khởi động lạnh, CPU của VM on-prem chờ đĩa 43–64% thời gian (w3 trên GCP 0%). Sau các bản sửa ngày 03/11, khởi động lạnh còn khoảng 6 phút (trước đó 11 phút), không cần can thiệp tay.

## 1. Mục tiêu

Dựng và vận hành một cụm Kubernetes theo cách làm của môi trường production:

- Triển khai bằng GitOps; code có pipeline CI/CD từ commit đến cụm, có kiểm tra bảo mật ở từng bước.
- Không để lộ secret trong Git; một nơi đăng nhập, phân quyền theo nhóm.
- Có giám sát, cảnh báo, quy trình vận hành hằng ngày, backup ngoài máy và kế hoạch lùi đã diễn tập.

## 2. Kiến trúc

Sơ đồ tổng thể, hạ tầng, luồng deploy và bảng thành phần: [kien-truc.md](kien-truc.md).

Tóm tắt: Talos v1.14.2, Kubernetes v1.37.1, Flannel, KubePrism, VIP Layer 2. cp1 2 vCPU/3,5 GB, w1 và w2 2 vCPU/4,5 GB, mạng NAT `10.10.10.0/24` trên kvm-host2 (i7-6700, 16 GB, 1 HDD); w3 là VM GCP e2-standard-2 8 GB ở asia-southeast1, bật 08:15–17:15 T2–T6. Truy cập từ LAN qua HAProxy :443 trên host2, tên miền `*.talos.internal`, chứng chỉ từ CA nội bộ.

Luồng đưa code lên production: push → Jenkins (gitleaks, test, govulncheck, gosec, SonarQube, build amd64 + arm64, Trivy, SBOM, cosign) → sửa `newTag` trong repo này → Argo CD → Harbor replicate từ GHCR → blue-green có kiểm tra. Đo ngày 28/10: khoảng 12 phút từ push tới khi bản mới nhận traffic.

## 3. Bảo mật

**Chuỗi cung ứng**

- Pipeline Jenkins: gitleaks quét toàn bộ lịch sử Git, govulncheck, gosec (từ mức medium), quality gate SonarQube có coverage, Trivy quét đúng digest đã đẩy (cả amd64 và arm64), SBOM CycloneDX, ký cosign. Mỗi cổng đã thử chặn bằng commit hoặc image lỗi cố ý.
- Kyverno (ImageValidatingPolicy) chỉ nhận image demo-app ký bằng khoá Jenkins, cả từ GHCR lẫn Harbor. Webhook chỉ ở namespace `demo` nên Kyverno lỗi không chặn được phần còn lại của cụm.
- ZAP baseline quét bản preview trước khi chuyển traffic.

**Secret**

- Secret hạ tầng trong Git chỉ ở dạng SealedSecret; khoá giải mã của Sealed Secrets đã được backup.
- Biến môi trường của ứng dụng nằm ở Vault (KV v2), External Secrets đưa vào pod. Vault tự unseal bằng GCP KMS, có audit log.
- File nhạy cảm của cụm (secret Talos, talosconfig, kubeconfig, snapshot etcd, khoá init Vault) chỉ nằm trên host2 trong thư mục quyền 700, không commit, không in ra màn hình hay chat.

**Đăng nhập và phân quyền**

- Keycloak (realm `talos`) cho Grafana, Argo CD, Headlamp, Vault, Harbor (OIDC), Jenkins, GitLab, SonarQube (SAML), Prometheus và Alertmanager (qua oauth2-proxy). Nhóm `talos-admins` có quyền quản trị, `talos-viewers` chỉ xem. Mỗi công cụ giữ một tài khoản dự phòng khi Keycloak hỏng.
- HAProxy chỉ nhận kết nối từ các IP được phép trong LAN. Pod Security Admission mức restricted cho `demo`, `headlamp`, `kyverno`.
- Argo CD đọc repo bằng deploy key chỉ đọc; Jenkins dùng deploy key riêng có quyền ghi để sửa tag. Cụm kéo image Harbor bằng robot chỉ có quyền pull.

## 4. Vận hành hằng ngày và backup

Host2 bị tắt cuối ngày (T2/T4 lúc 10:30, các ngày khác khoảng 17:00), nên cụm được bật/tắt có kiểm soát theo runbook.

**Buổi sáng**: đăng nhập captive portal trên host2 → bật host2 (VM tự bật) → kiểm tra node, Argo CD, Vault đã unseal, ExternalSecret, demo-app. Khởi động lạnh đo sáng 02/11: khoảng 11 phút 20 từ lúc host2 boot tới khi mọi app Healthy, không can thiệp tay (chi tiết mục 7).

**Cuối ngày**: backup (tự động 16:45, hoặc chạy tay nếu tắt sớm) → tạm dừng watchdog và healthchecks nếu tắt sớm → tắt cp1 → tắt 2 worker. Từ 03/11 tắt bằng `talosctl shutdown --force` (không drain) và tắt control plane trước, để pod giữ nguyên node và sáng hôm sau khởi động lại tại chỗ.

**Backup**

| Hạng mục | Chi tiết | Trạng thái |
|---|---|---|
| Lịch | systemd 16:45 trên host2 (ngoài cụm); tắt sớm thì chạy tay | Chạy hằng ngày, lần gần nhất 02/11 10:18 đủ 7 bước |
| Nội dung | snapshot etcd, dump DB Keycloak (Supabase), dump DB Harbor, snapshot Vault | OK |
| Ngoài máy | gói mã hóa GPG đẩy lên Backblaze B2 và Google Cloud Storage (tài khoản chỉ thêm được, không xoá được) | OK, đã thử giải mã |
| Object Kubernetes | Velero 09:30 T2–T6 lên bucket GCS riêng, giữ 30 ngày, không gồm dữ liệu PV | Cài 03/11; diễn tập khôi phục toàn cụm lên GCP dự kiến 05/11 |
| Cảnh báo lỗi | Telegram kèm log khi một bước lỗi | Đã thử |
| Khôi phục etcd từ snapshot | `talosctl bootstrap --recover-from` | Chưa diễn tập |
| Khôi phục Vault từ snapshot | `vault operator raft snapshot restore -force` vào Vault mới cùng KMS key; nơi khôi phục cần `/vault/audit` ghi được | Đã diễn tập 29/10: Vault tạm ở ns riêng, tự unseal, đọc được `kv/demo/demo-app`, khoảng 2,5 phút |

**Giám sát**: Prometheus, Alertmanager, Grafana; cảnh báo về Telegram cho demo-app, Argo CD, Keycloak, ExternalSecret, Vault (`VaultNotReady`), image có CVE CRITICAL (`ImageScanCritical`). Log mọi pod về VictoriaLogs, xem trên Grafana. Watchdog trên host2 và healthchecks.io báo khi cả cụm chết.

**Diễn tập đã làm**: tắt có kế hoạch 1 worker (22/10); lùi DB Keycloak về PostgreSQL trong cụm rồi tiến lại Supabase (27/10, SSO gián đoạn 3 phút 23 giây khi lùi).

## 5. Sự cố đã gặp và bài học

| Thời điểm | Sự cố | Xử lý và bài học |
|---|---|---|
| 14/10 | Lệnh dry-run ở maintenance mode in config kèm secret | Reset cụm, tạo secret mới. Cấm lệnh này; xem Secret chỉ theo tên khóa. |
| 15/10 | Host thiếu RAM, swap; Grafana thrash page cache, IO 30%, cả 3 apiserver unready | Giảm RAM CP, swappiness 10, nới timeout etcd, nâng limit Grafana. Gốc là HDD. |
| 16/10 sáng | Portal hết hạn, Talos chờ đồng bộ giờ, etcd không chạy | Cụm lấy giờ từ host2 qua KVM PTP, `bootTimeout` 2 phút. |
| 16/10 10:34 | Grafana chạm limit, đọc đĩa liên tục, API gián đoạn 11 phút | Grafana request 384Mi / limit 1Gi, sau đó DB Grafana lên PVC. |
| 20/10 | RAM và IO không đủ cho 3 control plane | Tắt cp2, cp3, còn 1 control plane; nhận rủi ro mất API khi cp1 lỗi. |
| 27/10 | Khi tiến lại Supabase, StatefulSet Keycloak kẹt vì pod cũ unready (`OrderedReady`) | Xóa pod để revision mới lên. Lần sau tách 2 commit: đổi app trước, tắt DB cũ sau. |
| 28/10 sáng | Host2 mất Internet: Vault không gọi được KMS nên không unseal, Argo CD không đọc được Git | Đăng nhập lại portal thì tự hồi phục. Thêm cảnh báo `VaultNotReady`. |
| 28/10 | Harbor trả 500 khi cấp token: khoá ký ở dạng PKCS#8 | Chuyển sang PKCS#1, sửa script sinh khoá. Bài học: thử thành phần mới qua đúng đường mà nơi dùng nó sẽ đi. |
| 29/10 08:37 | Khởi động lạnh: Keycloak build lại cấu hình, Vault, DB Harbor cùng đọc ghi đĩa; PSI io full khoảng 33%, etcd chậm, API mất khoảng 1 phút, controller-manager và scheduler restart | Tự hồi phục. Cùng gốc HDD; xem mục 6, 7. |
| 29/10 08:47–09:11 | w2 lên trước nên nhận gần hết pod (request RAM 88% nhưng limit 261%); Talos OOM-kill 2 lần, Grafana restart liên tục; Keycloak bị startup probe kill sau 20 phút build | Xoá pod Keycloak để sang w1, cụm sạch lúc 09:11 (khởi động lạnh khoảng 50 phút). Bài học: request thấp hơn mức dùng thật làm scheduler xếp quá tải một node; sửa bằng request sát thực tế và Keycloak image optimized. |
| 30/10 sáng | Khởi động lạnh khoảng 25 phút: w2 đầy request, Harbor Pending, Kyverno trả 503 nên demo-app 0 pod | Xoá tay 2 pod. Sửa gốc: PriorityClass `talos-pinned` cho các pod bị ghim w2, chuyển Prometheus, VictoriaLogs và bộ điều khiển lên w3. |
| 02/11 09:23 | Deploy dừng giữa chừng: Jenkins ghi tag mới trước khi Harbor kịp replicate (10 phút/lần), Kyverno từ chối, Argo CD thử lại 6 phút rồi bỏ | Bấm Sync tay; Argo CD thử lại khoảng 16 phút. Web không gián đoạn. |
| 03/11 sáng | Jenkins, GitLab, SonarQube trả 502: tunnel SSH nối trước khi có Internet, treo mà service vẫn `active` | Thêm `ConnectTimeout` cho tunnel để tự thử lại. |
| 03/11 sáng | Khởi động lạnh chậm hơn hôm trước (w2 96% request) | Gốc ở lúc tắt: drain dồn pod sang một node, kubelet đánh dấu pod `Failed` nên sáng hôm sau phải tạo lại và chờ Kyverno. Đổi cách tắt: không drain, tắt control plane trước. |

## 6. Giới hạn hiện tại

- **Một ổ HDD cho cả cụm.** PSI io lúc bình thường 10–25%, khi khởi động lạnh hoặc sự cố vượt 30%. Đây là giới hạn chính về độ ổn định.
- **Một control plane.** Mất cp1 là mất API cho tới khi bật lại; etcd chỉ có 1 member.
- **Một máy vật lý.** Không chống được lỗi host hay ổ đĩa; backup đã có bản ngoài máy (B2).
- **Phụ thuộc Internet qua captive portal.** Mất mạng thì Vault không unseal, Keycloak không vào DB (Supabase), Argo CD không đọc Git, không gửi được Telegram.
- **Thành phần có trạng thái ghim một worker.** Harbor, Grafana, Vault trên w2; Prometheus, VictoriaLogs trên w3; DB keycloak-db cũ trên w1. Worker đó tắt thì dịch vụ đó ngừng.
- **w3 phụ thuộc Internet công ty.** KubeSpan qua 2 lớp NAT, mất gói khoảng 1% (đo 30/10, là của đường Internet). w3 không tới được `*.talos.internal`, nên thứ cần Keycloak hoặc Harbor phải ở on-prem.
- **sudo không mật khẩu** trên host2 (từ 16/10) cho tiện thao tác lab; cần thu hồi khi kết thúc giai đoạn dựng.
- **Token có hạn**: PAT của Jenkins và GitLab đã gia hạn 02/11, hết hạn khoảng cuối tháng 1/2027.
- **11 image đang chạy còn CVE CRITICAL** (quét 02/11): 7 image Harbor (có bản sửa trong chart 1.19.4), argocd, k8s-sidecar, flannel chờ upstream, postgres dính CVE ở `gosu` mà pod không dùng.

## 7. Việc tiếp theo và đề xuất

**Số đo khởi động lạnh** (tới khi mọi app Healthy, không can thiệp tay trừ khi ghi):

| | 29/10 sáng | 29/10 10:16 | 02/11 | 03/11 sáng | 03/11 10:12 (sau sửa) | 03/11 10:51 | 03/11 13:16 (prefetch) | 04/11 sáng (bật thật) |
|---|---|---|---|---|---|---|---|---|
| Tổng (từ lúc bật VM) | khoảng 50 phút, xoá pod tay | 12:46 | khoảng 10:14 | 11:30 | 6:53 | 6:14 | **5:59** | 6:22 |
| demo-app 2 pod | | | +8:32 | +9:07 | +4:17 | +4:34 | | |
| Keycloak Ready | bị startup probe kill | khoảng 11 phút | khoảng 7:51 | +10:14 (JVM 280 giây) | +6:45 (JVM 98 giây) | +6:14 (JVM 111 giây) | +5:48 (JVM 29 giây) | **+5:16** |
| Request RAM w1 / w2 lúc lên | 19% / 88% | 93% / 81% | 72% / 64% | 50% / 96% | 64% / 73% | | | |
| CPU chờ đĩa (iowait) | | | khoảng 30% | 43–64% | 30–41% | | | |

Ba cột cuối đều là lần thử 03/11 có khởi động lại host2 (cache lạnh), sau 3 bản sửa: limit RAM của webhook external-secrets (trước đó đọc 10,7 GB từ đĩa trong 8 phút), tắt cụm không drain và tắt control plane trước, external-secrets kiểm tra chứng chỉ 30 giây. Cột 13:16 thêm sidecar `prefetch` cho Keycloak (đọc tuần tự 381 MB jar trước khi JVM chạy) và tắt 16 plugin Grafana không dùng. Chênh 6:53 và 6:14 là do thứ tự khởi động: Keycloak phải chờ DNS 8–40 giây vì EndpointSlice kube-dns còn trỏ IP CoreDNS cũ cho tới khi CoreDNS mới Ready. Lần 13:16, Keycloak, harbor-jobservice và Grafana về đích cách nhau 11 giây; cả cụm đọc khoảng 5,5 GB từ một ổ HDD, nên khoảng 6 phút là mức sàn nếu không đổi phần cứng. Cột 04/11 là lần bật máy thật buổi sáng đầu tiên sau các bản sửa (host2 tắt qua đêm): Keycloak nhanh hơn 13:16, tổng chậm hơn 23 giây vì harbor-jobservice khởi động trước harbor-core, CrashLoop một vòng, và Grafana về cuối.

Những gì đã sửa từ 29/10: request RAM theo p95 thực tế, Keycloak image optimized, PriorityClass cho pod bị ghim, chuyển Prometheus và bộ điều khiển lên w3, oauth2-proxy không còn phụ thuộc Keycloak lúc khởi động, external-secrets kiểm tra chứng chỉ 30 giây thay vì 5 phút, đổi cách tắt cụm, Keycloak đọc trước jar, Grafana tắt plugin không dùng. Đã thử và lùi AppCDS cho Keycloak (JVM sập khi nạp archive). Phần còn lại là giới hạn phần cứng, cần anh duyệt:

| Ưu tiên | Đề xuất (cần anh duyệt) | Căn cứ |
|---|---|---|
| Cao | **SSD cho đĩa VM** | Đo 03/11: 10 phút đầu khởi động lạnh, CPU của cp1, w1, w2 chờ đĩa 43%, 61%, 50% thời gian; w3 trên GCP 0%. Sau các bản sửa phần mềm còn khoảng 6 phút; lần 13:16 ba pod cuối về đích cách nhau 11 giây, cả cụm đọc khoảng 5,5 GB từ một ổ HDD. Sửa từng app không còn lợi đáng kể. |
| Trung bình | **Thêm RAM cho worker on-prem** | Từ khi có w3, request on-prem còn khoảng 64–73%; vẫn chật khi một worker tắt. Ưu tiên thấp hơn SSD. |
| Trung bình | **IaC cho tầng VM và Talos** (Terraform provider libvirt hoặc Ansible; cấu hình máy Talos trong Git) | Tầng Kubernetes đã là GitOps; tầng dưới (tạo VM, patch Talos, HAProxy, script backup trên host2) còn làm tay theo runbook. Chi tiết và thứ tự làm: [de-xuat-iac.md](de-xuat-iac.md). |

| Ưu tiên | Việc nhóm tự làm | Lý do |
|---|---|---|
| Cao | Diễn tập khôi phục toàn cụm lên GCP bằng Velero và gói backup (dự kiến 05/11) | Mới diễn tập riêng Vault; chưa đo được RTO toàn cụm. Thiết kế: `TTS_QTDV/design/velero-dien-tap-khoi-phuc.md`. |
| Trung bình | Nâng Harbor lên chart 1.19.4 (sau diễn tập, backup tay trước) | Hết 7 trong 11 image còn CVE CRITICAL. |
| Trung bình | Policy `require-memory-request` từ Warn sang Deny | Còn 3 chỗ thiếu request: helper pod local-path, `redisSecretInit` của Argo CD, script `make-secrets.sh` của Harbor. Deny trước khi sửa thì PVC mới sẽ kẹt. |
| Trung bình | Diễn tập khôi phục etcd từ snapshot (cần anh có mặt) | Vault đã diễn tập 29/10; etcd chưa. |
| Trung bình | Gỡ `keycloak-db` sau diễn tập | Dọn DB cũ khi hết thời gian giữ để lùi. |
| Thấp | Thu hồi sudo NOPASSWD trên host2 | Đưa cấu hình về gần production. |
