# Báo cáo hiện trạng cụm talos-kvm

Người thực hiện: Hưng, Phúc. Cập nhật: 15/11/2026 (bản trước: 12/11).

File này là báo cáo tổng hợp, cập nhật mỗi khi có thay đổi lớn. Chi tiết từng thay đổi theo ngày ở [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md); sơ đồ và thành phần ở [kien-truc.md](kien-truc.md); cách vào các giao diện ở [truy-cap.md](truy-cap.md).

## Tóm tắt

- Cụm Talos 1 control plane + 2 worker trên một máy KVM (kvm-host2), API qua VIP `10.10.10.100:6443`, thêm worker w3 trên Google Cloud nối bằng KubeSpan (chạy Prometheus, VictoriaLogs và các bộ điều khiển).
- GitOps bằng Argo CD. Jenkins trên Google Cloud là deployer: quét bảo mật, build, ký image, rồi sửa tag trong repo này. Argo Rollouts triển khai blue-green có smoke test, phân tích tỉ lệ lỗi và quét ZAP.
- **13/11 nâng phiên bản**:
  - Talos v1.14.2 → **v1.14.6** cả 4 node, từng node một bằng script mới `talos-upgrade-node.sh`;
  - Argo CD v3.5.7 → **v3.6.1**: hết 2 CVE CRITICAL;
  - image-scan còn **0 image có CVE CRITICAL**.
- **13/11 vá HA sau 2 sự cố lúc nâng** (demo-app ngừng 17 phút, Vault treo 18 phút):
  - Kyverno chạy 2 bản, mỗi worker một;
  - demo-app có PDB; descheduler rải lại pod theo topology;
  - Longhorn tự xoá pod Vault khi volume bị tách bất thường.
- **Từ 09/11 bỏ Harbor**: cụm kéo image thẳng từ GHCR, Kyverno chỉ cho chạy image có chữ ký của Jenkins. Secret của ứng dụng nằm ở Vault. Đăng nhập tập trung bằng Keycloak.
- **Longhorn** (từ 06/11, 2 bản sao trên w1 và w2): Grafana và Vault chạy trên đó. Mất một worker thì Vault và Keycloak tự lên lại ở worker kia sau khoảng 3,5 phút, không thao tác tay.
- **Backup** hằng ngày, mã hoá, lên Backblaze B2 và Google Cloud Storage:
  - từ 13/11 gói backup có thêm mọi khoá Sealed Secrets và CA nội bộ;
  - stop script không cho tắt cụm khi chưa có backup thành công trong 30 phút gần nhất;
  - watchdog báo Telegram khi backup cũ hơn 26 giờ.
- **Audit 10–12/11** (`TTS_QTDV/design/audit-10-11.md`): 13/11 đóng thêm các mục sau.
  - SSH host2: chỉ nhận khoá, chặn từ mạng pod/node, tắt rpcbind.
  - host2 hết quyền ghi GitHub. Nhánh `main` chặn force-push và xoá nhánh, bật secret scanning.
  - 5 cảnh báo control plane.
  - Bảng hạn credential.
  - Tài liệu khôi phục thảm hoạ.
- **Nút thắt lớn nhất vẫn là ổ HDD duy nhất.** Khởi động lạnh mất khoảng 8 phút, tính từ lúc libvirtd lên tới khi Grafana xanh (12/11: Vault +7:14, Grafana +7:57).

## 1. Mục tiêu

Dựng và vận hành một cụm Kubernetes theo cách làm của môi trường production:

- Triển khai bằng GitOps; code có pipeline CI/CD từ commit đến cụm, có kiểm tra bảo mật ở từng bước.
- Không để lộ secret trong Git; một nơi đăng nhập, phân quyền theo nhóm.
- Có giám sát, cảnh báo, quy trình vận hành hằng ngày, backup ngoài máy và kế hoạch lùi đã diễn tập.

## 2. Kiến trúc

Sơ đồ tổng thể, hạ tầng, luồng deploy và bảng thành phần: [kien-truc.md](kien-truc.md). Sáu sơ đồ đã vẽ lại theo 13/11.

**Phần mềm**
- Talos **v1.14.6** (từ 13/11), Kubernetes **v1.37.2** (từ 16/11), Flannel 0.28.10, KubePrism, VIP Layer 2, Longhorn 1.13.0, Argo CD **v3.6.1**.
- Nâng Kubernetes 1.37.2 sáng 16/11 (7,5 phút, API gián đoạn ngắn). Flannel nay cấp cho pod MTU 1330 (KubeSpan 1380 trừ 50 byte VXLAN), nên gói từ pod sang w3 không vượt MTU. Pod đã restart theo đợt; instance-manager của Longhorn giữ MTU cũ tới lần khởi động lạnh sau (restart nó sẽ ngắt volume).

**Máy**
- cp1 2 vCPU/4 GB và w1 2 vCPU/4 GB (12/11 chuyển 512 MiB từ w1 sang cp1, [de-xuat-ram-cp1.md](de-xuat-ram-cp1.md)); w2 2 vCPU/4,5 GB.
- Mạng NAT `10.10.10.0/24` trên kvm-host2 (i7-6700, 16 GB RAM, 1 HDD).
- w3 là VM GCP e2-standard-2 8 GB ở asia-southeast1, bật 08:15–17:15 T2–T6 (từ 16/11 T2/T4 không tắt sớm).
- Request RAM sau khi cân lại pod 13/11: w1 67 %, w2 78 %, w3 38 %.

**Truy cập:** từ LAN qua HAProxy :443 trên host2, tên miền `*.talos.internal`, chứng chỉ từ CA nội bộ.

**Luồng đưa code lên production:** push → Jenkins (gitleaks, test, govulncheck, gosec, SonarQube, build amd64 + arm64, Trivy, SBOM, cosign) → sửa `newTag` trong repo này → Argo CD → blue-green có kiểm tra. Từ 13/11 Jenkins dọn cache build sau mỗi lần chạy, để VM 4 GiB không đầy đĩa.

## 3. Bảo mật

**Chuỗi cung ứng**

- **Pipeline Jenkins:**
  - gitleaks quét toàn bộ lịch sử Git; govulncheck; gosec từ mức medium; quality gate SonarQube có coverage;
  - Trivy quét đúng digest đã đẩy (cả amd64 và arm64); SBOM CycloneDX; ký cosign.
  - Mỗi cổng đã thử chặn bằng commit hoặc image lỗi cố ý.
- **Kyverno 1.19.2:** chỉ nhận image demo-app ký bằng khoá Jenkins trên GHCR. Từ 13/11 chạy 2 bản, có PDB, nên drain một worker không chặn việc tạo pod.
- **ZAP baseline** quét bản preview trước khi chuyển traffic.
- **Quét image đang chạy** hằng ngày (Trivy). 13/11 còn 0 image có CVE CRITICAL:
  - nâng Argo CD 3.6.1;
  - bỏ qua có hạn tới 30/11 ba mã đã có bản vá nhưng chờ bản nâng (Longhorn 2, flannel 1).

**Secret**

- Secret hạ tầng trong Git chỉ ở dạng SealedSecret. Từ 13/11 mỗi lần backup đều xuất mọi khoá giải mã Sealed Secrets, nên khoá tự xoay vẫn có trong backup.
- Biến môi trường của ứng dụng nằm ở Vault (KV v2), External Secrets đưa vào pod. Vault tự unseal bằng GCP KMS, có audit log.
- File nhạy cảm của cụm chỉ nằm trên host2 trong thư mục quyền 700, không commit, không in ra màn hình hay chat.
- **Grafana và deploy key** (12/11):
  - service account của Grafana không còn đọc được Secret;
  - deploy key ghi cũ đã xoá.
- **Credential có hạn** (13/11):
  - lập bảng [han-credential.md](han-credential.md); PAT đọc của Jenkins đã gia hạn tới 11/02/2027;
  - sớm nhất trong bảng là PAT `ghcr-pull`, hết hạn 13/01/2027.
- **Repo public:** 13/11 nhánh `main` bật chặn force-push và xoá nhánh, cùng secret scanning. 15/11 đã bỏ IP LAN văn phòng khỏi tài liệu và patch Talos. Còn một chỗ trong values của Traefik, sẽ đổi 16/11.

**Đăng nhập và phân quyền**

- **Keycloak** (realm `talos`) là nơi đăng nhập chung:
  - qua OIDC: Grafana, Argo CD, Headlamp, Vault;
  - qua SAML: Jenkins, GitLab, SonarQube;
  - qua oauth2-proxy: Prometheus, Alertmanager và vmui VictoriaLogs.
  - Nhóm `talos-admins` có quyền quản trị, `talos-viewers` chỉ xem. Mỗi công cụ giữ một tài khoản dự phòng khi Keycloak hỏng.
- HAProxy chỉ nhận kết nối từ các IP được phép trong LAN. Pod Security Admission mức restricted cho `demo`, `headlamp`, `kyverno`.
- **host2** (13/11):
  - SSH chỉ nhận khoá, cấm root;
  - mạng VM và mạng pod không đăng nhập được vào host2;
  - rpcbind đã tắt; mật khẩu đã đổi;
  - host2 không còn quyền ghi GitHub.
- **Còn hở:**
  - sudo không mật khẩu trên host2 (chờ anh duyệt);
  - NetworkPolicy chưa có hiệu lực vì Flannel chưa bật bộ thực thi;
  - hai PAT push lên GHCR có scope `repo`, rộng hơn mức cần (chỉ cần `write:packages`).

## 4. Vận hành hằng ngày và backup

Host2 bị tắt cuối ngày (khoảng 17:00; từ 16/11 T2/T4 cũng làm cả ngày), nên cụm được bật/tắt có kiểm soát.

**Buổi sáng**: bật host2, VM tự bật, `talos-cluster-resume.service` trả các app về số bản cũ. Kiểm tra node, Argo CD, Vault đã unseal, ExternalSecret, demo-app. Watchdog tự kích External Secrets khi Vault lên muộn.

**Cuối ngày**: `~/bin/talos-cluster-stop.sh` (từ 10/11):
1. Backup nếu 30 phút gần nhất chưa có lần thành công. Backup lỗi thì dừng, không tắt (từ 12/11).
2. Tạm dừng Argo CD cho app có volume Longhorn, thu Grafana và Vault về 0 để Longhorn tách volume sạch.
3. Tắt w3 trên GCP (từ 13/11, nếu trước 17:15), rồi cp1, rồi w1, w2.

Sáng hôm sau Longhorn không phải dựng lại bản sao. Lần chạy 13/11: backup 16:39 thành công, 3 volume `detached`, mọi VM tắt trong 2 phút.

**Nâng Talos** (từ 13/11): `host2/bin/talos-upgrade-node.sh <ip> <version>`.
- Chạy không có `--yes` thì chỉ in kế hoạch và kiểm trước; thêm `--yes` mới nâng.
- Script tự làm:
  - đọc schematic đang chạy trên node để giữ extension;
  - kiểm Longhorn còn bản sao ở node khác;
  - chụp etcd trước khi nâng cp1;
  - gỡ pod CSI đang chặn drain;
  - chờ cụm ổn định mới thoát.
- Thứ tự đã dùng: w2, w1, w3, cp1. Bảo trì xong thì `rollout restart` các pod ưu tiên w3 để chúng về lại w3.

**Backup**

| Hạng mục | Chi tiết | Trạng thái |
|---|---|---|
| Lịch | systemd 16:45 trên host2, và stop script khi tắt cụm. Từ 12/11 timer 16:45 tự bỏ qua khi cụm đã tắt, không báo lỗi giả | Lần gần nhất 13/11 16:39 đủ các bước, 71 file, lên cả B2 và GCS |
| Nội dung | snapshot etcd, dump DB Keycloak (Supabase), snapshot Vault; từ 13/11 thêm mọi khoá Sealed Secrets và CA `talos-internal-ca` | OK |
| Ngoài máy | gói mã hoá GPG đẩy lên Backblaze B2 và Google Cloud Storage | OK |
| Object Kubernetes | Velero 09:30 T2–T6 lên bucket GCS riêng, giữ 30 ngày | Diễn tập khôi phục toàn cụm lên GCP 05/11: RTO khoảng 51–54 phút, RPO 6–7 phút |
| Cảnh báo | Telegram khi một bước lỗi; từ 12/11 watchdog báo khi backup thành công gần nhất cũ hơn 26 giờ | Đã thử |
| Khôi phục Vault | snapshot vào Vault mới cùng KMS key | Diễn tập 29/10 và 10/11 (trên Longhorn): 59 giây từ snapshot tới đọc được secret |
| Khôi phục etcd | `talosctl bootstrap --recover-from`, quy trình ở [khoi-phuc-tham-hoa.md](khoi-phuc-tham-hoa.md) (13/11) | Chưa diễn tập |

**Giám sát**
- **Prometheus, Alertmanager, Grafana**, cảnh báo về Telegram cho:
  - demo-app, Argo CD, Keycloak, ExternalSecret;
  - Vault (`VaultSealed`, `VaultDown`, `VaultNotReady`);
  - Longhorn (volume faulted/degraded), image có CVE CRITICAL.
- **Thêm 13/11:**
  - 5 cảnh báo control plane: apiserver restart, API mất ngắn, etcd chậm, IO cao;
  - `ContainerMemoryNearLimit`: RSS vượt 90 % limit RAM trong 10 phút.
- **Log** mọi pod về VictoriaLogs.
- **Ngoài cụm:**
  - watchdog trên host2 chạy 3 phút một lần, kiểm Internet, IO, VM, API, node, Prometheus, Alertmanager, tuổi backup, quyền xem dashboard Grafana;
  - từ 13/11, 09:00 T2–T6 `talos-upstream-check` báo khi Longhorn hoặc Talos có bản mới.

**Diễn tập đã làm**:
- Tắt có kế hoạch 1 worker (22/10).
- Lùi DB Keycloak (27/10).
- Khôi phục toàn cụm lên GCP (05/11).
- Rút điện w1 nhiều lần (06/11, 10/11). Lần 10/11, khi Vault đã ở trên Longhorn:
  - watchdog gắn taint `out-of-service` sau 1:55;
  - Vault Ready +3:34, Keycloak Ready +3:46, demo-app luôn còn pod chạy;
  - bật lại w1 thì 3 volume `healthy` sau 4:26.
- Nâng Talos lần lượt cả 4 node (13/11), mỗi node một lần khởi động lại có kế hoạch.

## 5. Sự cố đã gặp và bài học

| Thời điểm | Sự cố | Xử lý và bài học |
|---|---|---|
| 14/10 | Lệnh dry-run ở maintenance mode in config kèm secret | Reset cụm, tạo secret mới. Cấm lệnh này; xem Secret chỉ theo tên khoá. |
| 15–16/10 | Thiếu RAM, Grafana thrash page cache, API gián đoạn | Giảm RAM CP, nâng limit Grafana, DB Grafana lên PVC. Gốc là HDD. |
| 20/10 | RAM và IO không đủ cho 3 control plane | Tắt cp2, cp3, còn 1 control plane; nhận rủi ro mất API khi cp1 lỗi. |
| 28/10 sáng | Host2 mất Internet: Vault không unseal, Argo CD không đọc được Git | Đăng nhập lại portal thì tự hồi phục. Thêm cảnh báo `VaultNotReady`. |
| 29–30/10 | Khởi động lạnh 25–50 phút: một worker nhận gần hết pod, OOM-kill, Keycloak bị kill | Request RAM theo p95 thực tế, PriorityClass, chuyển Prometheus và bộ điều khiển lên w3. |
| 03/11 sáng | Tunnel SSH tới Jenkins/GitLab treo; khởi động lạnh chậm do drain dồn pod | `ConnectTimeout` cho tunnel; tắt không drain, control plane trước. |
| 06/11, 10/11, 12/11 | kube-apiserver trên cp1 bị kubelet kill (etcd chậm vì IO), API mất 15 giây tới khoảng 1 phút, controller-manager và scheduler restart theo. Lần 12/11 xảy ra lúc Argo CD áp cert-manager | Chuyển RAM sang cp1 (12/11) để có thêm page cache; 13/11 thêm 5 cảnh báo control plane, giảm ghi etcd (lease argo-rollouts dài hơn, descheduler 30 phút một lần). Gốc vẫn là HDD dùng chung. |
| 06/11 | Rút điện w1: Keycloak chờ 20 phút vì pod velero node-agent kẹt Terminating chiếm chỗ | Watchdog gắn taint `out-of-service` cho worker chết; bỏ node-agent của Velero (10/11). |
| 10/11 | Cả ngày không có backup: cụm tắt trước 16:45 mà không backup tay, timer 16:45 lỗi vì cụm đã tắt | Stop script tự backup trước khi tắt, timer bỏ qua khi cụm tắt, watchdog báo tuổi backup (12/11). |
| 12/11 | Sau khi Grafana khởi động lại, 1 dashboard mất quyền Viewer (provisioning bị huỷ giữa chừng; đã gặp 06/11) | Gán lại quyền trên UI; watchdog báo khi số dashboard người xem thấy lệch với số khai báo. |
| 13/11 10:45 | jenkins-1 (4 GiB) treo khi build: đổi bản Go làm mất cache, govulncheck và gosec biên dịch lại, chiếm khoảng 3 GiB | Cài sẵn công cụ vào volume theo phiên bản, giới hạn RAM container test 2,5 GB, dọn cache build sau mỗi lần; đĩa 84 % → 64 %. |
| 13/11 12:21 | Nâng Argo CD 3.6.1: hook `redis-secret-init` limit 64Mi không chứa nổi binary mới, kẹt 40 phút | Nâng limit lên 256Mi, xoá job, chạy lại thành công. Rà mọi limit RAM nhỏ (không thấy chỗ khác sát ngưỡng), thêm cảnh báo `ContainerMemoryNearLimit`. |
| 13/11 14:18–14:35 | Nâng Talos w1: cả 2 pod demo-app và Kyverno (1 bản, policy chặn khi Kyverno lỗi) cùng nằm trên w1; drain đuổi hết, không tạo được pod mới, demo-app ngừng 17 phút | PDB cho demo-app, Kyverno 2 bản mỗi worker một, descheduler rải lại pod theo topology. Thử drain dry-run sau đó: chỉ còn chặn đúng chỗ mong muốn. |
| 13/11 15:53–16:11 | Nâng Talos cp1: instance-manager Longhorn trên w2 bị tạo lại, engine volume Vault chết, ext4 trong pod báo I/O error, Vault treo 18 phút | Xoá pod vault-0 thì lên lại, dữ liệu nguyên. Longhorn nay tự xoá pod StatefulSet khi volume bị tách bất thường. Cảnh báo `VaultDown`, `VaultNotReady` đã gửi Telegram đúng lúc nhưng không ai xem: từ nay lúc bảo trì phải mở Telegram. |

## 6. Giới hạn hiện tại

- **Một ổ HDD cho cả cụm.** Lúc bình thường cp1 chờ đĩa khoảng 20% thời gian; khi khởi động lạnh hoặc rollout lớn thì etcd chậm và apiserver có thể bị kill. Đây là giới hạn chính về độ ổn định.
- **Một control plane.** Mất cp1 là mất API cho tới khi bật lại; etcd chỉ có 1 member.
- **Một máy vật lý.** Không chống được lỗi host hay ổ đĩa (ổ đã chạy khoảng 59.500 giờ); backup đã có bản ngoài máy.
- **Phụ thuộc Internet qua captive portal.** Mất mạng thì Vault không unseal, Keycloak không vào DB (Supabase), Argo CD không đọc Git, không gửi được Telegram.
- **Prometheus và VictoriaLogs ghim w3** (dữ liệu trên đĩa GCP): w3 tắt thì không có metric, log và cảnh báo trong cụm; watchdog ngoài cụm vẫn chạy.
- **Bảo trì làm xáo vị trí pod.** Sau khi drain, pod ưu tiên w3 dồn về w1/w2 (request RAM lên 98 %) cho tới khi `rollout restart`. Instance-manager Longhorn bị tạo lại có thể làm chết volume đang gắn, như sự cố Vault 13/11.
- **Log dịch vụ Talos (etcd, kubelet) chỉ nằm trong RAM của node**, giữ khoảng 45 phút; audit log apiserver giữ khoảng 1 ngày.
- **sudo không mật khẩu** trên host2; thu hẹp sau, cần anh duyệt.
- **Hạn cần nhớ:**
  - danh sách bỏ qua CVE của image-scan hết hạn 30/11: quét 17/11 xác nhận flannel v0.28.10 vẫn còn mã brotli, chưa có Longhorn 1.13.1; các gói không được nạp lúc chạy. Kế hoạch: nâng khi có bản vá, nếu tới 27/11 chưa có thì gia hạn tới 31/12 ([ke-hoach-cve-30-11.md](ke-hoach-cve-30-11.md));
  - PAT `ghcr-pull` hết hạn 13/01/2027;
  - GCP Free Trial (gồm khoá KMS của Vault) hết 22/01/2027.

## 7. Việc tiếp theo và đề xuất

Thứ tự đầy đủ ở `TTS_QTDV/design/audit-10-11.md` mục 7. Việc gần nhất:

| Khi | Việc | Cần anh |
|---|---|---|
| 16/11 sáng (xong) | Đo khởi động lạnh (Vault không chậm thêm); nâng Kubernetes 1.37.2 (MTU pod 1330, restart pod theo đợt); `ingressEndpoint` của Traefik dùng IP giữ chỗ `10.10.10.100` | Không |
| 17/11 sáng (xong) | Nâng Vault 2.0.4 → 2.2.2 (bản 2.2.2 ra 12/11, mới hơn 2.2.1 dự kiến); Traefik 3.7.18 và Keycloak 26.8.2 đã nâng 16/11 | Không |
| Trước 30/11 | Nâng Longhorn 1.13.1 khi có bản (upstream-check sẽ báo) hoặc gia hạn danh sách bỏ qua CVE có lý do | Không |
| Lần gia hạn PAT tới | Tạo lại 2 PAT push chỉ với `write:packages` | Không |
| Sắp lịch | Diễn tập khôi phục etcd trên cụm tạm theo [khoi-phuc-tham-hoa.md](khoi-phuc-tham-hoa.md) | Không, nhưng anh nên biết lịch |
| Sau | Bật NetworkPolicy (Flannel), gửi log Talos ra VictoriaLogs, metrics etcd, thu hẹp sudo trên host2 | Duyệt từng bước |

| Ưu tiên | Đề xuất (cần anh duyệt) | Căn cứ |
|---|---|---|
| Cao | **SSD cho đĩa VM** | Mọi sự cố control plane gần đây đều do IO của HDD dùng chung; sửa phần mềm không còn lợi đáng kể. |
| Cao | **Laptop bật BitLocker, repo ghi chú TTS_QTDV có remote private** | 2 mục high của audit: laptop giữ khoá SSH, token GCP, khoá init Vault dạng rõ; ghi chú DR chỉ có trên một máy. |
| Cần anh quyết | Quyền write của Phúc trên talos-gitops; tài khoản GCP break-glass thứ hai | Audit #12, #9. |
| Cần anh quyết | Có xoá IP LAN văn phòng khỏi lịch sử git của repo public không | Phải viết lại lịch sử, force-push (tạm tắt bảo vệ `main`) và clone lại ở host2, Argo CD, Jenkins. |
