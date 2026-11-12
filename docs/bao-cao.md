# Báo cáo hiện trạng cụm talos-kvm

Người thực hiện: Hưng, Phúc. Cập nhật: 12/11/2026 (bản trước: 03/11).

File này là báo cáo tổng hợp, cập nhật mỗi khi có thay đổi lớn. Chi tiết từng thay đổi theo ngày ở [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md); sơ đồ và thành phần ở [kien-truc.md](kien-truc.md); cách vào các giao diện ở [truy-cap.md](truy-cap.md).

## Tóm tắt

- Cụm Talos 1 control plane + 2 worker trên một máy KVM (kvm-host2), API qua VIP `10.10.10.100:6443`, thêm worker w3 trên Google Cloud nối bằng KubeSpan (chạy Prometheus, VictoriaLogs và các bộ điều khiển).
- GitOps bằng Argo CD. Jenkins trên Google Cloud là deployer: quét bảo mật, build, ký image, rồi sửa tag trong repo này. Argo Rollouts triển khai blue-green có smoke test, phân tích tỉ lệ lỗi và quét ZAP.
- **Từ 09/11 bỏ Harbor**: cụm kéo image thẳng từ GHCR, Kyverno chỉ cho chạy image có chữ ký của Jenkins. Secret của ứng dụng nằm ở Vault. Đăng nhập tập trung bằng Keycloak.
- **Từ 06/11 có lưu trữ chung Longhorn** (2 bản sao trên w1, w2): Grafana (06/11) và Vault (10/11) chạy trên Longhorn, nên mất một worker thì Vault và Keycloak tự lên lại ở worker kia sau khoảng 3,5 phút, không thao tác tay.
- Backup hằng ngày mã hoá lên Backblaze B2 và Google Cloud Storage. Từ 12/11 script tắt cụm không cho tắt khi chưa có backup thành công trong 30 phút gần nhất, và watchdog báo Telegram khi backup cũ hơn 26 giờ.
- 10–12/11 audit toàn hệ thống (chỉ đọc): còn mở 29 mục, 2 high, 13 medium; đã sửa 5 mục ngay trong lúc audit. Báo cáo: `TTS_QTDV/design/audit-10-11.md`.
- Nút thắt lớn nhất vẫn là ổ HDD duy nhất. Khởi động lạnh hiện khoảng 8 phút từ lúc libvirtd lên tới khi Grafana xanh (12/11: Vault +7:14, Grafana +7:57).

## 1. Mục tiêu

Dựng và vận hành một cụm Kubernetes theo cách làm của môi trường production:

- Triển khai bằng GitOps; code có pipeline CI/CD từ commit đến cụm, có kiểm tra bảo mật ở từng bước.
- Không để lộ secret trong Git; một nơi đăng nhập, phân quyền theo nhóm.
- Có giám sát, cảnh báo, quy trình vận hành hằng ngày, backup ngoài máy và kế hoạch lùi đã diễn tập.

## 2. Kiến trúc

Sơ đồ tổng thể, hạ tầng, luồng deploy và bảng thành phần: [kien-truc.md](kien-truc.md).

Tóm tắt: Talos v1.14.2, Kubernetes v1.37.1, Flannel, KubePrism, VIP Layer 2, Longhorn 1.13.0. **Từ 12/11 cp1 2 vCPU/4 GB, w1 2 vCPU/4 GB** (chuyển 512 MiB từ w1 sang cp1, [de-xuat-ram-cp1.md](de-xuat-ram-cp1.md)), w2 2 vCPU/4,5 GB, mạng NAT `10.10.10.0/24` trên kvm-host2 (i7-6700, 16 GB, 1 HDD); w3 là VM GCP e2-standard-2 8 GB ở asia-southeast1, bật 08:15–17:15 (T2/T4 tắt 10:40). Truy cập từ LAN qua HAProxy :443 trên host2, tên miền `*.talos.internal`, chứng chỉ từ CA nội bộ.

Luồng đưa code lên production: push → Jenkins (gitleaks, test, govulncheck, gosec, SonarQube, build amd64 + arm64, Trivy, SBOM, cosign) → sửa `newTag` trong repo này → Argo CD → blue-green có kiểm tra. Từ khi bỏ Harbor không còn bước chờ replicate.

## 3. Bảo mật

**Chuỗi cung ứng**

- Pipeline Jenkins: gitleaks quét toàn bộ lịch sử Git, govulncheck, gosec (từ mức medium), quality gate SonarQube có coverage, Trivy quét đúng digest đã đẩy (cả amd64 và arm64), SBOM CycloneDX, ký cosign. Mỗi cổng đã thử chặn bằng commit hoặc image lỗi cố ý.
- Kyverno 1.19.2 (từ 12/11, bản vá lỗi bỏ qua kiểm chữ ký) chỉ nhận image demo-app ký bằng khoá Jenkins trên GHCR. Đã thử sau khi nâng: ảnh ký qua, ảnh không ký bị chặn.
- ZAP baseline quét bản preview trước khi chuyển traffic.

**Secret**

- Secret hạ tầng trong Git chỉ ở dạng SealedSecret; khoá giải mã của Sealed Secrets đã được backup (bản xuất cần làm mới trước 16/11, xem mục 7).
- Biến môi trường của ứng dụng nằm ở Vault (KV v2), External Secrets đưa vào pod. Vault tự unseal bằng GCP KMS, có audit log.
- File nhạy cảm của cụm chỉ nằm trên host2 trong thư mục quyền 700, không commit, không in ra màn hình hay chat.
- 12/11: service account của Grafana không còn đọc được Secret (trước đó chart cấp quyền đọc mọi Secret trong cụm); deploy key ghi cũ của GitHub Actions đã xoá, chỉ còn key chỉ đọc của Argo CD và key ghi của Jenkins.

**Đăng nhập và phân quyền**

- Keycloak (realm `talos`) cho Grafana, Argo CD, Headlamp, Vault (OIDC), Jenkins, GitLab, SonarQube (SAML), Prometheus, Alertmanager và vmui VictoriaLogs (qua oauth2-proxy). Nhóm `talos-admins` có quyền quản trị, `talos-viewers` chỉ xem. Mỗi công cụ giữ một tài khoản dự phòng khi Keycloak hỏng.
- HAProxy chỉ nhận kết nối từ các IP được phép trong LAN. Pod Security Admission mức restricted cho `demo`, `headlamp`, `kyverno`.
- Còn hở (từ audit, đang sửa): host2 cho đăng nhập SSH bằng mật khẩu và pod/node tới thẳng được cổng 22; NetworkPolicy chưa có hiệu lực vì Flannel chưa bật bộ thực thi.

## 4. Vận hành hằng ngày và backup

Host2 bị tắt cuối ngày (T2/T4 lúc 10:30, các ngày khác khoảng 17:00), nên cụm được bật/tắt có kiểm soát.

**Buổi sáng**: bật host2, VM tự bật, `talos-cluster-resume.service` trả các app về số bản cũ. Kiểm tra node, Argo CD, Vault đã unseal, ExternalSecret, demo-app. Watchdog tự kích External Secrets khi Vault lên muộn.

**Cuối ngày**: `~/bin/talos-cluster-stop.sh` (từ 10/11):
1. Backup nếu 30 phút gần nhất chưa có lần thành công; backup lỗi thì dừng, không tắt (từ 12/11).
2. Tạm dừng Argo CD cho app có volume Longhorn, thu Grafana và Vault về 0 để Longhorn tách volume sạch.
3. Tắt cp1 trước, rồi w1, w2.

Sáng hôm sau Longhorn không phải dựng lại bản sao.

**Backup**

| Hạng mục | Chi tiết | Trạng thái |
|---|---|---|
| Lịch | systemd 16:45 trên host2, và stop script khi tắt cụm. Từ 12/11 timer 16:45 tự bỏ qua khi cụm đã tắt, không báo lỗi giả | Lần gần nhất 12/11 15:13 đủ các bước |
| Nội dung | snapshot etcd, dump DB Keycloak (Supabase), snapshot Vault | OK (Harbor đã bỏ 09/11) |
| Ngoài máy | gói mã hoá GPG đẩy lên Backblaze B2 và Google Cloud Storage | OK |
| Object Kubernetes | Velero 09:30 T2–T6 lên bucket GCS riêng, giữ 30 ngày | Diễn tập khôi phục toàn cụm lên GCP 05/11: RTO khoảng 51–54 phút, RPO 6–7 phút |
| Cảnh báo | Telegram khi một bước lỗi; từ 12/11 watchdog báo khi backup thành công gần nhất cũ hơn 26 giờ | Đã thử |
| Khôi phục Vault | snapshot vào Vault mới cùng KMS key | Diễn tập 29/10 và 10/11 (trên Longhorn): 59 giây từ snapshot tới đọc được secret |
| Khôi phục etcd | `talosctl bootstrap --recover-from` | Chưa diễn tập |

**Giám sát**: Prometheus, Alertmanager, Grafana; cảnh báo về Telegram cho demo-app, Argo CD, Keycloak, ExternalSecret, Vault (`VaultSealed`, `VaultDown`, `VaultNotReady`), Longhorn (volume faulted/degraded), image có CVE CRITICAL. Log mọi pod về VictoriaLogs. Watchdog trên host2 (3 phút/lần) kiểm từ ngoài cụm: Internet, IO, VM, API, node, Prometheus, Alertmanager, và từ 12/11 thêm tuổi backup và quyền xem dashboard Grafana.

**Diễn tập đã làm**:
- Tắt có kế hoạch 1 worker (22/10).
- Lùi DB Keycloak (27/10).
- Khôi phục toàn cụm lên GCP (05/11).
- Rút điện w1 nhiều lần (06/11, 10/11). Lần 10/11, khi Vault đã ở trên Longhorn: watchdog gắn taint `out-of-service` sau 1:55, Vault Ready +3:34, Keycloak Ready +3:46, demo-app luôn còn pod chạy; bật lại w1 thì 3 volume `healthy` sau 4:26.

## 5. Sự cố đã gặp và bài học

| Thời điểm | Sự cố | Xử lý và bài học |
|---|---|---|
| 14/10 | Lệnh dry-run ở maintenance mode in config kèm secret | Reset cụm, tạo secret mới. Cấm lệnh này; xem Secret chỉ theo tên khoá. |
| 15–16/10 | Thiếu RAM, Grafana thrash page cache, API gián đoạn | Giảm RAM CP, nâng limit Grafana, DB Grafana lên PVC. Gốc là HDD. |
| 20/10 | RAM và IO không đủ cho 3 control plane | Tắt cp2, cp3, còn 1 control plane; nhận rủi ro mất API khi cp1 lỗi. |
| 28/10 sáng | Host2 mất Internet: Vault không unseal, Argo CD không đọc được Git | Đăng nhập lại portal thì tự hồi phục. Thêm cảnh báo `VaultNotReady`. |
| 29–30/10 | Khởi động lạnh 25–50 phút: một worker nhận gần hết pod, OOM-kill, Keycloak bị kill | Request RAM theo p95 thực tế, PriorityClass, chuyển Prometheus và bộ điều khiển lên w3. |
| 03/11 sáng | Tunnel SSH tới Jenkins/GitLab treo; khởi động lạnh chậm do drain dồn pod | `ConnectTimeout` cho tunnel; tắt không drain, control plane trước. |
| 06/11, 10/11, 12/11 | kube-apiserver trên cp1 bị kubelet kill (etcd chậm vì IO), API mất 15 giây tới khoảng 1 phút, controller-manager và scheduler restart theo. Lần 12/11 xảy ra lúc Argo CD áp cert-manager | Không có cảnh báo nào bắn. Đã chuyển RAM sang cp1 (12/11) để có thêm page cache; sẽ thêm rule cảnh báo restart control plane. Gốc vẫn là HDD dùng chung. |
| 06/11 | Rút điện w1: Keycloak chờ 20 phút vì pod velero node-agent kẹt Terminating chiếm chỗ | Watchdog gắn taint `out-of-service` cho worker chết; bỏ node-agent của Velero (10/11). |
| 10/11 | Cả ngày không có backup: cụm tắt trước 16:45 mà không backup tay, timer 16:45 lỗi vì cụm đã tắt | Stop script tự backup trước khi tắt, timer bỏ qua khi cụm tắt, watchdog báo tuổi backup (12/11). |
| 12/11 | Sau khi Grafana khởi động lại, 1 dashboard mất quyền Viewer (provisioning bị huỷ giữa chừng; đã gặp 06/11) | Gán lại quyền trên UI; watchdog báo khi số dashboard người xem thấy lệch với số khai báo. |

## 6. Giới hạn hiện tại

- **Một ổ HDD cho cả cụm.** Lúc bình thường cp1 chờ đĩa khoảng 20% thời gian; khi khởi động lạnh hoặc rollout lớn thì etcd chậm và apiserver có thể bị kill. Đây là giới hạn chính về độ ổn định.
- **Một control plane.** Mất cp1 là mất API cho tới khi bật lại; etcd chỉ có 1 member.
- **Một máy vật lý.** Không chống được lỗi host hay ổ đĩa (ổ đã chạy khoảng 59.500 giờ); backup đã có bản ngoài máy.
- **Phụ thuộc Internet qua captive portal.** Mất mạng thì Vault không unseal, Keycloak không vào DB (Supabase), Argo CD không đọc Git, không gửi được Telegram.
- **Prometheus và VictoriaLogs ghim w3** (dữ liệu trên đĩa GCP): w3 tắt thì không có metric, log và cảnh báo trong cụm; watchdog ngoài cụm vẫn chạy.
- **Log dịch vụ Talos (etcd, kubelet) chỉ nằm trong RAM của node**, giữ khoảng 45 phút; audit log apiserver giữ khoảng 1 ngày.
- **sudo không mật khẩu** trên host2; thu hẹp sau, cần anh duyệt.
- **Token có hạn**: PAT Jenkins phải gia hạn trước 22/11. GCP Free Trial (gồm khoá KMS của Vault) hết 22/01/2027.

## 7. Việc tiếp theo và đề xuất

Thứ tự đầy đủ ở `TTS_QTDV/design/audit-10-11.md` mục 7. Việc gần nhất:

| Khi | Việc | Cần anh |
|---|---|---|
| 13/11 sáng | Đo lại RAM và IO của cp1 sau khi đổi RAM; chặn SSH từ dải pod/node, tắt rpcbind | Không |
| Trước 16/11 | Sửa gói backup để có khoá Sealed Secrets hiện hành (khoá tự xoay khoảng 14/11) | Duyệt, vì đụng chuỗi backup |
| Khi máy Phúc có khoá | Tắt đăng nhập SSH bằng mật khẩu trên host2, đổi mật khẩu | Không |
| Tuần này | Rule cảnh báo restart control plane; bảng hạn credential, gia hạn PAT Jenkins | Không |
| 17/11 sáng | Nâng Traefik, sau đó Keycloak 26.8.2, Vault 2.2.1 | Không |
| Sau | Bật NetworkPolicy (Flannel), gửi log Talos ra VictoriaLogs, metrics etcd | Duyệt từng bước |

| Ưu tiên | Đề xuất (cần anh duyệt) | Căn cứ |
|---|---|---|
| Cao | **SSD cho đĩa VM** | Mọi sự cố control plane gần đây đều do IO của HDD dùng chung; sửa phần mềm không còn lợi đáng kể. |
| Cao | **Laptop bật BitLocker, repo ghi chú TTS_QTDV có remote private** | 2 mục high của audit: laptop giữ khoá SSH, token GCP, khoá init Vault dạng rõ; ghi chú DR chỉ có trên một máy. |
| Cần anh quyết | Quyền write của Phúc trên talos-gitops; tài khoản GCP break-glass thứ hai | Audit #12, #9. |
