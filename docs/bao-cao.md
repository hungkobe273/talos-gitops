# Báo cáo hiện trạng cụm talos-kvm

Người thực hiện: Hưng, Phúc. Cập nhật: 29/10/2026.

File này là báo cáo tổng hợp, cập nhật mỗi khi có thay đổi lớn. Chi tiết từng thay đổi theo ngày ở [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md); sơ đồ và thành phần ở [kien-truc.md](kien-truc.md); cách vào các giao diện ở [truy-cap.md](truy-cap.md).

## Tóm tắt

- Cụm Talos 1 control plane + 2 worker trên một máy KVM (kvm-host2 `192.168.136.38`), API qua VIP `10.10.10.100:6443`. cp2, cp3 đã tắt từ 20/10 để tiết kiệm RAM và IO.
- GitOps bằng Argo CD (18 app). Jenkins trên Google Cloud là deployer: quét bảo mật, build, ký image, rồi sửa tag trong repo này. Argo Rollouts triển khai blue-green có smoke test, phân tích tỉ lệ lỗi và quét ZAP.
- Cụm kéo image từ Harbor nội bộ; Kyverno chỉ cho chạy image có chữ ký của Jenkins. Secret của ứng dụng nằm ở Vault. Đăng nhập tập trung bằng Keycloak cho 8 công cụ.
- Giám sát và cảnh báo về Telegram, watchdog ngoài cụm, backup hằng ngày mã hóa lên Backblaze B2.
- Nút thắt lớn nhất vẫn là ổ HDD duy nhất: lúc khởi động lạnh, IO có thể làm etcd chậm và API gián đoạn ngắn (gặp lại sáng 29/10).

## 1. Mục tiêu

Dựng và vận hành một cụm Kubernetes theo cách làm của môi trường production:

- Triển khai bằng GitOps; code có pipeline CI/CD từ commit đến cụm, có kiểm tra bảo mật ở từng bước.
- Không để lộ secret trong Git; một nơi đăng nhập, phân quyền theo nhóm.
- Có giám sát, cảnh báo, quy trình vận hành hằng ngày, backup ngoài máy và kế hoạch lùi đã diễn tập.

## 2. Kiến trúc

Sơ đồ tổng thể, hạ tầng, luồng deploy và bảng thành phần: [kien-truc.md](kien-truc.md).

Tóm tắt: Talos v1.14.2, Kubernetes v1.37.1, Flannel, KubePrism, VIP Layer 2. cp1 2 vCPU/3,5 GB, w1 và w2 2 vCPU/4,5 GB, mạng NAT `10.10.10.0/24` trên kvm-host2 (i7-6700, 16 GB, 1 HDD). Truy cập từ LAN qua HAProxy :443 trên host2, tên miền `*.talos.internal`, chứng chỉ từ CA nội bộ.

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

**Buổi sáng**: đăng nhập captive portal trên host2 → bật host2 (VM tự bật) → kiểm tra node, Argo CD, Vault đã unseal, ExternalSecret, demo-app. Khởi động lạnh đo ngày 28/10: 9 phút 29 giây tới khi mọi app Healthy.

**Cuối ngày**: backup (tự động 16:45, hoặc chạy tay nếu tắt sớm) → tạm dừng watchdog và healthchecks nếu tắt sớm → tắt 2 worker → tắt cp1.

**Backup**

| Hạng mục | Chi tiết | Trạng thái |
|---|---|---|
| Lịch | systemd 16:45 trên host2 (ngoài cụm); tắt sớm thì chạy tay | Chạy hằng ngày, lần gần nhất 28/10 10:10 đủ 6 bước |
| Nội dung | snapshot etcd, dump DB Keycloak (Supabase), dump DB Harbor, snapshot Vault | OK |
| Ngoài máy | gói mã hóa GPG đẩy lên Backblaze B2 | OK, đã thử giải mã |
| Cảnh báo lỗi | Telegram kèm log khi một bước lỗi | Đã thử |
| Khôi phục etcd từ snapshot | `talosctl bootstrap --recover-from` | Chưa diễn tập |
| Khôi phục Vault từ snapshot | `vault operator raft snapshot restore` | Chưa diễn tập |

**Giám sát**: Prometheus, Alertmanager, Grafana; cảnh báo về Telegram cho demo-app, Argo CD, Keycloak, ExternalSecret, Vault (`VaultNotReady`). Watchdog trên host2 và healthchecks.io báo khi cả cụm chết.

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

## 6. Giới hạn hiện tại

- **Một ổ HDD cho cả cụm.** PSI io lúc bình thường 10–25%, khi khởi động lạnh hoặc sự cố vượt 30%. Đây là giới hạn chính về độ ổn định.
- **Một control plane.** Mất cp1 là mất API cho tới khi bật lại; etcd chỉ có 1 member.
- **Một máy vật lý.** Không chống được lỗi host hay ổ đĩa; backup đã có bản ngoài máy (B2).
- **Phụ thuộc Internet qua captive portal.** Mất mạng thì Vault không unseal, Keycloak không vào DB (Supabase), Argo CD không đọc Git, không gửi được Telegram.
- **Thành phần có trạng thái ghim một worker.** Harbor, Grafana trên w2; Prometheus, DB keycloak-db cũ trên w1. Worker đó tắt thì dịch vụ đó ngừng.
- **sudo không mật khẩu** trên host2 (từ 16/10) cho tiện thao tác lab; cần thu hồi khi kết thúc giai đoạn dựng.
- **Token có hạn**: PAT đọc repo và đẩy image của Jenkins hết hạn khoảng 22/11/2026, cần gia hạn trước.

## 7. Việc tiếp theo và đề xuất

| Ưu tiên | Việc | Lý do |
|---|---|---|
| Cao | Xin SSD cho đĩa VM (cần anh duyệt) | Gốc của các lần API gián đoạn; etcd cần độ trễ fsync thấp. |
| Cao | Diễn tập khôi phục Vault và etcd từ snapshot | Backup chưa thử khôi phục thì chưa tin cậy được. |
| Trung bình | Giảm tải lúc khởi động lạnh: Keycloak build sẵn cấu hình (`start --optimized`), bật các app nặng theo đợt | Tránh IO dồn một lúc làm etcd chậm (sự cố 29/10). |
| Trung bình | Gia hạn PAT của Jenkins trước 22/11; gỡ `keycloak-db` sau 06/11 | Tránh pipeline hỏng; dọn DB cũ khi hết thời gian giữ để lùi. |
| Thấp | Thu hồi sudo NOPASSWD trên host2 | Đưa cấu hình về gần production. |
