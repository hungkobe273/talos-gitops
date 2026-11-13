# Khôi phục thảm hoạ cụm talos-kvm

Người soạn: Hưng. Ngày 13/11/2026 (audit dr3 bước 3). Trạng thái: bản đầu, **chưa diễn tập theo đúng tài liệu này**. Phần dựng cụm mới trên GCP đã diễn tập ngày 05/11 (RTO 50:52, RPO 6–7 phút), phần khôi phục Vault đã diễn tập 29/10 và 10/11. Phần `talosctl bootstrap --recover-from` và dựng lại host2 chưa thử.

Tài liệu này trả lời: mất thứ gì thì lấy lại từ đâu, theo thứ tự nào. Lệnh chi tiết từng bước nằm ở runbook nội bộ và các tài liệu được dẫn; ở đây giữ khung để người khác (anh, Phúc) làm theo được khi Hưng vắng.

## 1. Có gì để khôi phục

| Nguồn | Chứa gì | Ở đâu | Giữ |
|---|---|---|---|
| Repo `talos-gitops` (GitHub, public) | Mọi manifest, values Helm, app Argo CD, SealedSecret (đã mã hoá); patch Talos (`talos/`); file host2: XML libvirt, unit systemd, script, cấu hình ssh (`host2/`); Terraform GCP (`infra/gcp/`) | GitHub | Toàn bộ lịch sử; nhánh `main` có ruleset chặn force-push và xoá |
| Bundle offsite (GPG) | Snapshot etcd, pg_dump Keycloak, snapshot Vault Raft, `vault-init.json`, `vault-snapshot-token`, `secrets.yaml` Talos, `talosconfig`, `kubeconfig`, machine config `cp1/w1/w2/w3.yaml`, patch, khoá Sealed Secrets (xuất mỗi lần backup), Secret `talos-internal-ca`, `velero-repo-credentials`, khoá Argo CD, mật khẩu `*-password.txt`, script `~/bin`, unit systemd, khoá tunnel GCP, `haproxy.cfg` | host2 `~/talos-kvm/offsite/` (3 bản), Backblaze B2, Google Cloud Storage (30 ngày), laptop Hưng (14 bản) | Mỗi ngày làm việc 16:45 và mỗi lần tắt cụm sớm |
| Velero | Toàn bộ object Kubernetes (không có dữ liệu volume từ 10/11) | Bucket GCS `talos-kvm-velero-vtc` | `velero-daily` 02:30 T2–T6, 30 ngày |
| Supabase | DB Keycloak (dịch vụ ngoài, không mất theo host2) | Supabase | Theo Supabase; pg_dump hằng ngày nằm trong bundle |
| GCP KMS | Khoá auto-unseal của Vault | GCP | Không được xoá: mất khoá này thì snapshot Vault chỉ mở được bằng recovery keys |

Chỉ laptop của Hưng có khoá GPG bí mật để giải mã bundle (host2 chỉ có khoá công khai). Bản xuất khoá bí mật phải có ở một nơi thứ hai (USB hoặc trình quản lý mật khẩu). **Mất khoá GPG hoặc passphrase thì mọi bundle vô dụng.**

## 2. Chọn kịch bản

| Mất gì | Mức | Làm theo | Thời gian ước tính |
|---|---|---|---|
| Một pod hoặc một volume Longhorn hỏng | Nhỏ | Runbook phần Longhorn/Vault; Longhorn dựng lại bản sao từ worker kia | 5–30 phút |
| Đĩa của w1 hoặc w2 | Vừa | Mục 3 | 30–60 phút |
| etcd hỏng, cp1 còn | Lớn | Mục 4 | 30–60 phút, chưa diễn tập |
| Đĩa cp1 | Lớn | Mục 4 (cài lại cp1 trước) | 1 giờ, chưa diễn tập |
| Cả host2 (ổ HDD chết, máy hỏng) | Rất lớn | Mục 5: dựng tạm trên GCP (đã diễn tập) rồi dựng lại host2 | Tạm: khoảng 1 giờ. host2: nửa ngày |
| Laptop Hưng | Rất lớn với backup | Mục 6 | – |

Quy tắc chung:

- Trước khi sửa gì: nếu cụm còn đọc được, chạy backup tay (`sudo systemctl start talos-etcd-backup.service` trên host2) để có mốc mới nhất.
- Giải nén bundle vào thư mục tạm có quyền 700, xoá ngay sau khi dùng: bundle chứa toàn bộ bí mật của cụm.
- Mọi lệnh `talosctl apply-config` phải có `--dry-run` trước; không bao giờ dùng `--insecure` với node đang chạy.

## 3. Mất đĩa một worker (w1 hoặc w2)

1. Trên host2: tạo lại đĩa hệ thống `qemu-img create -f qcow2 /var/lib/libvirt/images/w1.qcow2 <cỡ>`, đĩa Longhorn `w1-longhorn.qcow2` 20G nếu mất. XML VM ở `host2/libvirt/` (`virsh define` nếu VM cũng mất).
2. Boot từ ISO Talos v1.14.2 (đã gắn sẵn ở cdrom trong XML). Node vào chế độ maintenance.
3. Áp machine config `w1.yaml` lấy từ bundle (đã gồm mọi patch). Đây là node mới chưa có cấu hình, nên lần áp đầu buộc phải dùng chế độ maintenance; làm đúng một lần, với đúng file của node đó.
4. Xoá node cũ trong Kubernetes nếu còn (`kubectl delete node <tên cũ>`), đợi node mới Ready.
5. Longhorn tự dựng lại bản sao volume từ worker còn lại. Kiểm: mọi volume `healthy`, Vault `Sealed false`, Grafana lên.

## 4. etcd hỏng hoặc mất cp1

Cụm chỉ có một control plane, nên etcd hỏng là mất API.

1. Lấy snapshot etcd mới nhất: trên host2 `ls -1t ~/talos-kvm/etcd-backups/ | head -1`; host2 mất thì lấy từ bundle.
2. Nếu mất đĩa cp1: cài lại cp1 như mục 3, áp `cp1.yaml` từ bundle, nhưng **không** chạy `talosctl bootstrap` thường.
3. Khôi phục: `talosctl -n 10.10.10.11 bootstrap --recover-from=<file.db>`. Talos dựng etcd một thành viên từ snapshot.
4. Đợi API lên. Worker giữ nguyên, kubelet nối lại. Kiểm node, Argo CD, Vault, Longhorn.
5. Dữ liệu ghi sau lần snapshot đó bị mất (RPO tới 24 giờ nếu dùng bản 16:45). Argo CD tự đưa manifest về đúng Git; chỉ trạng thái không nằm trong Git (ví dụ Secret tạo tay) cần kiểm lại.

Phần này chưa diễn tập trên cụm này: nên thử một lần trên cụm tạm trước khi phải dùng thật.

## 5. Mất cả host2

### 5.1 Dựng cụm tạm trên GCP (đã diễn tập 05/11)

Làm theo kịch bản `TTS_QTDV/design/velero-dien-tap-khoi-phuc.md` (bước 8 trở đi). Tóm tắt thứ tự:

1. Trên laptop: giải mã bundle mới nhất (từ B2 hoặc GCS nếu laptop chưa kéo bản mới).
2. Tạo VM trên GCP, sinh machine config từ `secrets.yaml` trong bundle, dựng cụm Talos.
3. Áp khoá Sealed Secrets từ `k8s-secrets/sealed-secrets-keys.yaml` **trước** khi cài Argo CD, để SealedSecret trong Git giải được. Áp `talos-internal-ca` và `velero-repo-credentials` cùng lúc.
4. Cài Velero chỉ đọc, restore Secret gốc; cài Argo CD và app `root` trỏ về `talos-gitops`.
5. Khôi phục Vault từ snapshot (mục 7.1), Keycloak dùng Supabase như cũ (hoặc DB trong cụm từ dump nếu Supabase cũng mất).
6. Đường vào `*.talos.internal` và các tích hợp (Jenkins, GitLab trên GCP vẫn còn) theo mục 5 của kịch bản.

Lần diễn tập đo được RTO 50:52 cho dịch vụ chính, 54:06 đầy đủ.

### 5.2 Dựng lại host2

1. Cài Ubuntu 24.04, user `ngochung`, gói: libvirt/qemu, haproxy, talosctl, kubectl, curl, python3, gpg (chỉ khoá công khai `talos-offsite-pub.asc` trong bundle).
2. Clone `talos-gitops` (HTTPS, không cần khoá).
3. libvirt: theo `host2/libvirt/README.md` (mạng `talos-net`, pool `images`, VM `cp1`, `w1`, `w2`).
4. Chép từ bundle vào `~/talos-kvm/`: `secrets.yaml`, `talosconfig`, `kubeconfig`, machine config, `vault-init.json`, `vault-snapshot-token`, các `*-password.txt` (quyền 600). Khoá tunnel GCP về `~/.ssh/gcp-tunnel`.
5. Dựng VM và cụm: đĩa mới, áp machine config, `bootstrap --recover-from` snapshot etcd (mục 4) hoặc bootstrap mới rồi để Argo CD dựng lại từ Git.
6. Cài lại phần host: `host2/bin/*.sh` vào `~/bin`, `host2/systemd/*` vào `/etc/systemd/system/` (rồi `daemon-reload`, `enable --now` các timer), `host2/ssh/*` vào `/etc/ssh/sshd_config.d/`, `haproxy.cfg` từ bundle, `host2/udev`, `host2/modules-load`.
7. Tạo lại các file bí mật nằm ngoài bundle (root 700, cố ý không đưa vào bundle): token bot Telegram (`/etc/talos-etcd-backup/`), khoá B2 (`/etc/talos-offsite-b2/`), khoá GCS (`/etc/talos-offsite-*`), ping URL healthchecks nếu dùng. Lấy lại từ trang quản trị của từng dịch vụ.
8. Kiểm: `talos-watchdog` mọi mục OK, chạy backup tay một lần, bundle lên B2 và GCS.

Khi host2 mới chạy ổn, chuyển dữ liệu từ cụm tạm GCP về (Vault snapshot mới, Velero restore nếu có thay đổi) rồi xoá cụm tạm.

## 6. Mất laptop của Hưng

- Bundle vẫn còn trên host2, B2, GCS, nhưng chỉ giải được bằng khoá GPG bí mật. Lấy bản xuất khoá từ nơi cất thứ hai, nhập vào máy mới (`gpg --import`), thử giải mã một bundle (chỉ liệt kê tên file).
- Không có bản khoá thứ hai: tạo khoá GPG mới, đổi `K` và `ENC_SUB` trong `host2/bin/talos-offsite-bundle.sh`, chạy backup ngay. Các bundle cũ coi như mất.
- `vault-init.json` có bản trên host2; laptop chỉ là bản sao.

## 7. Khôi phục từng thành phần

### 7.1 Vault

Cần: snapshot `vault-*.snap`, khoá GCP KMS còn nguyên, `vault-init.json` (recovery keys, root token).

1. Vault mới trống: `vault operator init -recovery-shares=1 -recovery-threshold=1`, lưu kết quả vào file 600.
2. `vault operator raft snapshot restore -force <file.snap>` bằng root token mới. Vault tự unseal bằng KMS.
3. Từ đây dùng root token và recovery keys cũ. Kiểm `kv/`, ClusterSecretStore `vault` Valid, `demo-app-env` đồng bộ.

Mẫu lệnh đầy đủ: `TTS_QTDV/design/vault-drill-longhorn/drill.sh` (diễn tập 10/11, 59 giây).

### 7.2 Keycloak

DB nằm trên Supabase nên mất cụm không mất DB. Nếu DB hỏng: `pg_restore --clean --if-exists` từ dump `keycloak-*.dump` trong bundle vào DB Supabase, lúc Keycloak đang scale về 0.

### 7.3 Sealed Secrets

Khoá chủ tự xoay 30 ngày một lần; bundle có mọi khoá còn trong cụm lúc backup. Áp toàn bộ `sealed-secrets-keys.yaml` vào `kube-system` trước khi controller khởi động (hoặc khởi động lại controller sau khi áp). SealedSecret seal bằng khoá nào cũng giải được miễn khoá đó có trong file.

### 7.4 Velero

Velero chỉ còn object Kubernetes. Dùng để lấy lại Secret và tài nguyên tạo tay không có trong Git. Restore từng namespace hoặc từng loại tài nguyên, không restore cả cụm một lần (Argo CD đã dựng phần trong Git).

## 8. Việc còn thiếu

- Diễn tập mục 4 (`bootstrap --recover-from`) trên cụm tạm.
- Kiểm bản xuất khoá GPG bí mật có ở nơi thứ hai.
- Danh sách gói và phiên bản chính xác cho host2 (mục 5.2 bước 1).
- Ghi RTO thật cho mục 5.2 khi có dịp dựng lại host2.
