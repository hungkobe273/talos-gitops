# Khôi phục thảm hoạ cụm talos-kvm

Người soạn: Hưng. Ngày 13/11/2026 (audit dr3 bước 3), sửa cùng ngày theo bản rà độc lập (15 điểm). Trạng thái: **chưa diễn tập theo đúng tài liệu này**. Đã diễn tập: dựng cụm mới trên GCP (05/11, RTO 50:52, RPO 6–7 phút, nhưng lúc đó host2 còn sống), khôi phục Vault (29/10, 10/11). Chưa thử: `talosctl bootstrap --recover-from`, áp khoá từ `k8s-secrets/` của bundle, dựng lại host2, dựng cụm tạm khi host2 đã chết.

Tài liệu này trả lời: mất thứ gì thì lấy lại từ đâu, theo thứ tự nào, để người khác (anh, Phúc) làm theo được khi Hưng vắng.

## 1. Có gì để khôi phục

| Nguồn | Chứa gì | Ở đâu | Giữ |
|---|---|---|---|
| Repo `talos-gitops` (GitHub, public) | Manifest, values Helm, app Argo CD, SealedSecret (đã mã hoá); patch Talos (`talos/`); file host2: XML libvirt, mọi unit systemd, script, cấu hình ssh, khoá GPG công khai (`host2/`); Terraform GCP (`infra/gcp/`) | GitHub | Toàn bộ lịch sử; `main` có ruleset chặn force-push và xoá |
| Bundle offsite (GPG) | Xem bảng 1.1 | host2 `~/talos-kvm/offsite/` (3 bản), Backblaze B2 `talos-kvm-offsite-vtc`, GCS `talos-kvm-offsite-gcs-vtc` (30 ngày), laptop Hưng `talos-backups\bundles\` (14 bản) | Mỗi ngày làm việc 16:45 và mỗi lần tắt cụm sớm |
| Velero | Object Kubernetes (không có dữ liệu volume từ 10/11) | GCS `talos-kvm-velero-vtc` | `velero-daily` 02:30 T2–T6, 30 ngày |
| Supabase | DB Keycloak (dịch vụ ngoài, không mất theo host2) | Supabase | pg_dump hằng ngày nằm trong bundle |
| GCP KMS | Khoá auto-unseal của Vault | GCP | Không được xoá: mất khoá thì snapshot Vault chỉ mở được bằng recovery keys |

### 1.1 Bundle chứa gì (theo `host2/bin/talos-offsite-bundle.sh`)

Trong gói, đường dẫn bỏ dấu `/` đầu, ví dụ `home/ngochung/talos-kvm/...`.

- Dữ liệu: snapshot etcd mới nhất (`etcd-backups/`), pg_dump Keycloak (`keycloak-backups/`), snapshot Vault (`vault-backups/`).
- Bí mật cụm: `vault-init.json`, `vault-snapshot-token`, `secrets.yaml` (Talos), `talosconfig`, `kubeconfig`, `argocd-deploy-key`, `*-password.txt`, `sealed-secrets-key-backup-*.yaml` (bản xuất tay 15/10).
- Từ 13/11, thư mục `k8s-secrets/`: `sealed-secrets-keys.yaml` (mọi khoá Sealed Secrets lúc backup), `talos-internal-ca.yaml`, `velero-repo-credentials.yaml`.
- Talos: machine config `cp1.yaml`, `w1.yaml`, `w2.yaml`, `w3.yaml`, `patch-*.yaml`, `patches/*.yaml`.
- host2: `~/bin/*.sh`, `coldstart-watch.sh`, khoá tunnel `~/.ssh/gcp-tunnel(.pub)`, `/etc/haproxy/haproxy.cfg`, unit `talos-etcd-backup*` (kèm thư mục `.service.d`), `talos-watchdog*`, `talos-cluster-resume.service`, `gcp-tunnel-*.service`, `coldstart-watch.service`. Unit còn lại (ví dụ drop-in `apt-daily*`) lấy từ `host2/systemd/` trong Git.
- **Không có** (cố ý, xem 5.2 bước 7): `/etc/talos-etcd-backup/`, `/etc/talos-offsite-b2/`, `/etc/talos-offsite-gcs/`, `/etc/talos-watchdog/`.

### 1.2 Ai mở được bundle

- Khoá GPG bí mật (fingerprint `18EB2C2685E44E04420E4FA8E84A7734379A711E`, khoá con mã hoá `A3A3652F43CEBFFD`) nằm trên laptop Hưng, homedir riêng `~/.gnupg-talos` (không phải homedir mặc định), cùng bản xuất `talos-backups\talos-offsite-SECRET-key.asc`. Bản thứ hai phải nằm ở USB hoặc trình quản lý mật khẩu, kèm passphrase. **Hiện chưa kiểm bản thứ hai có thật không (mục 8).** Mất khoá hoặc passphrase thì mọi bundle vô dụng.
- Khoá công khai: `host2/gpg/talos-offsite-pub.asc` trong repo.
- Tải bundle: B2 và GCS hiện chỉ tài khoản của Hưng (Owner project GCP, tài khoản B2) vào được. Để người khác khôi phục được khi Hưng vắng, cần cấp trước quyền đọc bucket cho anh (mục 8). Lệnh tải từ GCS:
  ```bash
  gcloud storage ls gs://talos-kvm-offsite-gcs-vtc/ | tail -3
  gcloud storage cp gs://talos-kvm-offsite-gcs-vtc/<tên file>.tar.gz.gpg .
  ```
- Giải mã (chỉ liệt kê tên file): `gpg --homedir ~/.gnupg-talos --pinentry-mode loopback -d <file> | tar tzf -`. Khôi phục thật: giải nén vào thư mục 700, xoá ngay sau khi dùng.

## 2. Chọn kịch bản

| Mất gì | Mức | Làm theo | Thời gian ước tính |
|---|---|---|---|
| Một pod hoặc một volume Longhorn hỏng | Nhỏ | Runbook phần Longhorn/Vault; Longhorn dựng lại bản sao từ worker kia | 5–30 phút |
| Đĩa của w1 hoặc w2 | Vừa | Mục 3 | 30–60 phút |
| w3 (GCP) | Vừa | Mục 3, cuối mục | 30 phút |
| etcd hỏng, cp1 còn | Lớn | Mục 4 | 30–60 phút, chưa diễn tập |
| Đĩa cp1 | Lớn | Mục 4 (cài lại cp1 trước) | 1 giờ, chưa diễn tập |
| Cả host2 (ổ HDD chết, máy hỏng) | Rất lớn | Mục 5 | Tạm trên GCP: 1–2 giờ. host2: nửa ngày |
| Laptop Hưng | Rất lớn với backup | Mục 6 | – |

Quy tắc chung:

- Trước khi sửa gì: nếu cụm còn đọc được, chạy backup tay (`sudo systemctl start talos-etcd-backup.service` trên host2) để có mốc mới nhất.
- Mọi `talosctl apply-config` lên node đang chạy phải `--dry-run` trước; không dùng `--insecure` với node đang chạy.

## 3. Mất đĩa một worker

1. Trên host2: xem cỡ đĩa cũ trong XML hoặc `virsh domblkinfo w1 vda` của worker còn lại, rồi `qemu-img create -f qcow2 /var/lib/libvirt/images/w1.qcow2 <cỡ đó>`. Đĩa Longhorn `w1-longhorn.qcow2` 20G nếu mất. XML VM ở `host2/libvirt/` (`virsh define` nếu VM cũng mất).
2. Boot từ ISO `talos-v1.14.2-qga-amd64.iso` (đã gắn ở cdrom trong XML; mất ISO thì tải lại từ Image Factory theo schematic trong `talos/`). Node vào chế độ maintenance.
3. Áp `w1.yaml` lấy từ bundle (đã gồm mọi patch). Node mới chưa có cấu hình nên lần áp đầu buộc phải dùng chế độ maintenance (`--insecure`); làm đúng một lần, với đúng file của node đó, và chắc chắn IP đó là VM mới.
4. Xoá node cũ trong Kubernetes nếu còn (`kubectl delete node <tên cũ>`), đợi node mới Ready.
5. Longhorn tự dựng lại bản sao từ worker còn lại. Kiểm: mọi volume `healthy`, Vault `Sealed false`, Grafana lên.

w3 (GCP): VM tạo bằng Terraform (`infra/gcp/compute.tf`, image `talos-v1-14-2` trong project). Mất VM: `terraform apply` tạo lại, rồi áp `w3.yaml` từ bundle. Image GCE mất thì tạo lại từ ảnh GCP của Talos 1.14.2 trước.

## 4. etcd hỏng hoặc mất cp1

Cụm chỉ có một control plane, nên etcd hỏng là mất API.

1. Lấy snapshot: trên host2 `ls -1t ~/talos-kvm/etcd-backups/ | head -1`. host2 mất thì giải nén từ bundle:
   ```bash
   tar xzf <bundle>.tar.gz --strip-components=4 home/ngochung/talos-kvm/etcd-backups/
   ```
2. `talosconfig` trong bundle trỏ endpoint `10.10.10.11` (cp1). Chạy từ máy trong mạng `10.10.10.0/24` (host2), hoặc sửa endpoint nếu dựng ở nơi khác.
3. Mất đĩa cp1: cài lại cp1 như mục 3 với `cp1.yaml`, nhưng **không** chạy `talosctl bootstrap` thường. etcd hỏng mà đĩa còn: `talosctl -n 10.10.10.11 reset --system-labels-to-wipe EPHEMERAL --reboot --graceful=false` để xoá dữ liệu etcd cũ.
4. Khôi phục: `talosctl -e 10.10.10.11 -n 10.10.10.11 bootstrap --recover-from=./etcd-backup-<ngày>.db`. Snapshot lấy bằng `talosctl etcd snapshot` có hash; file copy thẳng từ thư mục dữ liệu etcd thì thêm `--recover-skip-hash-check`.
5. Đợi API lên. Worker giữ nguyên, kubelet nối lại. Kiểm node, Argo CD, Vault, Longhorn.
6. Dữ liệu ghi sau snapshot bị mất (tới 24 giờ nếu dùng bản 16:45). Argo CD đưa manifest về đúng Git; trạng thái không nằm trong Git (Secret tạo tay) cần kiểm lại.

Chưa diễn tập: nên thử một lần trên cụm tạm trước khi phải dùng thật.

## 5. Mất cả host2

### 5.1 Dựng cụm tạm trên GCP

Dựa trên diễn tập 05/11 (`TTS_QTDV/design/velero-dien-tap-khoi-phuc.md`, bước 8 trở đi), nhưng **kịch bản đó chạy lệnh trên host2**. Khi host2 đã chết, máy trạm là laptop, hoặc một VM GCP tạm cài `talosctl` 1.14.2, `kubectl`, `helm`, `jq`, `kubeseal`, `gcloud`, `vault`. Mọi lệnh `ssh kvm-host2 '...'` trong kịch bản chạy thẳng trên máy trạm.

1. Tải và giải mã bundle mới nhất (mục 1.2) vào thư mục 700 trên máy trạm.
2. Chọn secret cụm:
   - **Mặc định: secret mới** (`talosctl gen config` không có `--with-secrets`), như lúc diễn tập. Lý do: dùng lại `secrets.yaml` thì Discovery/KubeSpan coi VM tạm là thành viên cụm cũ, và w3 (nếu còn chạy) sẽ cố nối vào.
   - Chỉ dùng `secrets.yaml` cũ khi định giữ cụm tạm làm cụm chính lâu dài; khi đó tắt hoặc xoá w3 trước.
3. Kiểm image GCE `talos-v1-14-2` còn trong project (`gcloud compute images list --filter=name~talos`), tạo firewall và VM như bước 9 của kịch bản, dựng cụm như bước 10.
4. Áp Secret gốc **trước** khi cài Argo CD (chưa diễn tập theo cách này; lúc diễn tập lấy bằng Velero restore). Bỏ metadata của cụm cũ rồi áp:
   ```bash
   for f in sealed-secrets-keys talos-internal-ca velero-repo-credentials; do
     yq 'del(.. | .resourceVersion?, .uid?, .creationTimestamp?, .managedFields?)' k8s-secrets/$f.yaml | kubectl apply -f -
   done
   ```
   Namespace `kube-system` có sẵn; tạo `cert-manager`, `velero` trước nếu chưa có.
5. Velero chỉ đọc: tạo lại SA chỉ đọc như bước 6 của kịch bản (`objectViewer` cả bucket, `objectCreator` chỉ dưới `talos-kvm/restores/`), đặt BackupStorageLocation `accessMode: ReadOnly`. **Không** dùng SA của SealedSecret trong Git: SA đó ghi và xoá được bucket backup thật.
6. Cài Argo CD và app `root` trỏ về `talos-gitops`. Khôi phục Vault (mục 7.1). Keycloak dùng Supabase như cũ (hoặc DB trong cụm từ dump nếu Supabase cũng mất).
7. Đường vào khi chạy thật (khác diễn tập, lúc đó dùng tên `drill-*` và chấp nhận `gcp-tools` 502):
   - Tên node: các pod ghim theo hostname (`talos-iv6-z5m`, `w3`) cần đặt `HostnameConfig` cho VM mới đúng tên đó, hoặc sửa nodeSelector trong Git.
   - `*.talos.internal`: StaticHostConfig trên node cho `keycloak.talos.internal` trỏ IP của Traefik mới; người dùng sửa file hosts (hoặc DNS) trỏ các tên về IP ngoài của Traefik trên GCP.
   - Jenkins, GitLab trên GCP còn nguyên; tunnel cũ từ host2 mất, nên `gcp-tools` cần trỏ thẳng tới IP nội bộ của hai VM đó.

### 5.2 Dựng lại host2

1. Cài Ubuntu 24.04, user `ngochung`. Gói: libvirt/qemu, haproxy, curl, python3, gpg, `talosctl` 1.14.2, `kubectl`, `helm`, `jq`, `kubeseal`, `vault`. ISO `talos-v1.14.2-qga-amd64.iso` (Image Factory, schematic trong `talos/`). Nhập khoá công khai `host2/gpg/talos-offsite-pub.asc`.
2. Clone `talos-gitops` (HTTPS, không cần khoá).
3. libvirt: theo `host2/libvirt/README.md` (mạng `talos-net`, pool `images`, VM `cp1`, `w1`, `w2`).
4. Chép từ bundle vào `~/talos-kvm/`: `secrets.yaml`, `talosconfig`, `kubeconfig`, machine config, `vault-init.json`, `vault-snapshot-token`, `*-password.txt` (quyền 600). Khoá tunnel về `~/.ssh/gcp-tunnel`.
5. Dựng VM và cụm: đĩa mới, áp machine config, rồi `bootstrap --recover-from` snapshot etcd (mục 4), hoặc bootstrap mới và để Argo CD dựng lại từ Git (khi đó áp Secret gốc như 5.1 bước 4).
6. Phần host: `host2/bin/*.sh` vào `~/bin`, `host2/systemd/*` vào `/etc/systemd/system/` (rồi `daemon-reload`, `enable --now` các timer), `host2/ssh/*` vào `/etc/ssh/sshd_config.d/` (rồi `sshd -t`, `reload ssh`), `haproxy.cfg` từ bundle, `host2/udev`, `host2/modules-load`.
7. Tạo lại bí mật không có trong bundle (thư mục root 700, file root 600):

   | File | Dùng cho | Tạo lại |
   |---|---|---|
   | `/etc/talos-etcd-backup/telegram-bot-token` | Cảnh báo backup lỗi, watchdog | Token bot từ @BotFather (bot hiện có, hoặc bot mới rồi sửa chat id trong `talos-watchdog.service`) |
   | `/etc/talos-offsite-b2/key-id`, `app-key` | Đẩy bundle lên B2 | Trang B2: tạo Application Key mới chỉ cho bucket `talos-kvm-offsite-vtc`, quyền ghi |
   | `/etc/talos-offsite-gcs/` (khoá JSON) | Đẩy bundle lên GCS | Tạo khoá mới cho SA `talos-backup-writer` (chỉ `roles/storage.objectCreator` trên bucket), xoá khoá cũ |
   | `/etc/talos-watchdog/hc-ping-url` | Ping healthchecks.io (tuỳ chọn) | Trang healthchecks.io; chỉ cần nếu bật drop-in `10-healthchecks.conf` |

8. Kiểm: `talos-watchdog` mọi mục OK, chạy backup tay một lần, bundle lên B2 và GCS.

Khi host2 mới chạy ổn, chuyển dữ liệu từ cụm tạm GCP về (Vault snapshot mới, Velero restore nếu có thay đổi) rồi xoá cụm tạm.

## 6. Mất laptop của Hưng

- Bundle vẫn còn trên host2, B2, GCS, nhưng chỉ giải được bằng khoá GPG bí mật. Lấy bản thứ hai (mục 1.2), nhập vào máy mới với homedir riêng (`gpg --homedir ~/.gnupg-talos --import <file>`), thử giải mã một bundle (chỉ liệt kê tên).
- Không có bản thứ hai: tạo khoá GPG mới, đổi `K` và `ENC_SUB` trong `host2/bin/talos-offsite-bundle.sh` và `host2/gpg/`, chạy backup ngay. Các bundle cũ coi như mất.
- Mất cả laptop lẫn host2 cùng lúc: nguồn duy nhất của `vault-init.json`, `secrets.yaml` và các mật khẩu là bundle, tức phụ thuộc hoàn toàn vào bản thứ hai của khoá GPG.

## 7. Khôi phục từng thành phần

### 7.1 Vault

Cần: snapshot `vault-*.snap`, khoá GCP KMS còn nguyên, `vault-init.json` (recovery keys, root token).

1. Vault mới trống: `vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json`, lưu kết quả vào file 600.
2. `vault operator raft snapshot restore -force <file.snap>` bằng root token mới. Vault tự unseal bằng KMS.
3. Từ đây dùng root token và recovery keys cũ. Kiểm `kv/`, ClusterSecretStore `vault` Valid, `demo-app-env` đồng bộ.

Mẫu lệnh đầy đủ: `TTS_QTDV/design/vault-drill-longhorn/drill.sh` (diễn tập 10/11, 59 giây).

### 7.2 Keycloak

DB nằm trên Supabase nên mất cụm không mất DB. DB hỏng: `pg_restore --clean --if-exists` từ dump `keycloak-*.dump` trong bundle vào DB Supabase, lúc Keycloak đang scale về 0.

### 7.3 Sealed Secrets

Khoá chủ tự xoay 30 ngày một lần; `k8s-secrets/sealed-secrets-keys.yaml` có mọi khoá còn trong cụm lúc backup. Áp như 5.1 bước 4 (bỏ metadata cũ) trước khi controller khởi động, hoặc khởi động lại controller sau khi áp. SealedSecret seal bằng khoá nào cũng giải được miễn khoá đó có trong file. Chưa diễn tập theo cách này.

### 7.4 Velero

Velero chỉ còn object Kubernetes. Dùng để lấy lại Secret và tài nguyên tạo tay không có trong Git. Restore từng namespace hoặc từng loại tài nguyên, không restore cả cụm một lần (Argo CD đã dựng phần trong Git). Luôn dùng SA chỉ đọc (5.1 bước 5) trên cụm khác cụm gốc.

## 8. Việc còn thiếu

- Kiểm bản thứ hai của khoá GPG bí mật và passphrase có thật, ở đâu, ai giữ.
- Cấp quyền đọc bucket GCS `talos-kvm-offsite-gcs-vtc` (và tài khoản B2) cho anh, để khôi phục được khi Hưng vắng.
- Diễn tập mục 4 (`bootstrap --recover-from`) và 5.1 bước 4 (áp khoá từ `k8s-secrets/`) trên cụm tạm.
- Ghi cỡ đĩa hệ thống của cp1, w1, w2 vào `host2/libvirt/README.md`.
- Ghi RTO thật cho mục 5.2 khi có dịp dựng lại host2.
