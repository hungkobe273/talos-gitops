# Bàn giao cho Phúc – thứ 4, 25/11/2026

Người giao: Hưng (nghỉ ngày 25/11). Cụm: `talos-kvm` trên host2. Hôm nay Phúc vận hành một mình.

Cách dùng: mở session AI (Claude hoặc Gemini) trong một thư mục trống, dán link file này hoặc nội dung file, rồi nói "làm việc 1". AI **chỉ soạn lệnh**, Phúc tự chạy rồi dán kết quả lại. Làm theo thứ tự.

## 1. Tình hình cuối ngày 23/11 (đọc trước)

Chi tiết ở [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md), mục 23/11.

- **Argo CD đã lên v3.6.2** (chart 10.18.2, helm rev 18 deployed 14:24). Lúc kiểm, 23/25 app Synced/Healthy. Hai app `monitoring` và `victoria-logs` hỏng vì Prometheus và VictoriaLogs chỉ chạy trên w3, mà w3 đang mất kết nối.
- **Sự cố w3 13:17, chưa sửa:** KubeSpan tới w3 mất sau 6 phút chạy. Các node on-prem gửi handshake WireGuard (UDP 51820) tới w3 nhưng không có gói trả về. Đã thử `gcloud reset` và stop/start, không đỡ. Firewall GCP vẫn đúng. Đang nghi mạng công ty chặn hoặc giới hạn UDP, nhưng chưa có bằng chứng.
- Vì w3 mất, các pod ưu tiên w3 dồn về w1/w2: RAM request của w1 là 94 %, w2 là 82 %. Velero đã scale về 0 lúc 14:11.
- **Backup Keycloak 23/11 lỗi:** pod `kc-backup-*` Pending vì thiếu RAM. Cụm được tắt bằng `--skip-backup-check`. Backup Keycloak OK gần nhất là 20/11. Snapshot etcd 23/11 thì OK.
- 24/11 cả công ty nghỉ, cụm không bật.

Lịch w3 (Cloud Scheduler): bật 08:15, **T4 tắt 10:40**.

## 2. Nguyên tắc

- **Không dán vào chat AI:** nội dung kubeconfig, talosconfig, machine config, Secret, token, mật khẩu, file `~/talos-kvm/*` và IP LAN công ty. Secret chỉ xem tên và loại.
- Mỗi lệnh trên host2 bọc dạng `ssh kvm-host2 'date +%T; export KUBECONFIG=~/talos-kvm/kubeconfig TALOSCONFIG=~/talos-kvm/talosconfig; ...'`. Không lồng nháy kép hai tầng.
- **Lệnh READ** (`kubectl get/describe/logs`, `talosctl get/logs`, `tcpdump` đọc gói) thì chạy thoải mái.
- **Lệnh CHANGE** chỉ gồm những lệnh ghi trong các việc dưới đây. Lệnh nào khác thì dừng lại, nhắn Hưng.
- Không bao giờ:
  - chạy `talosctl apply-config` hay SSH vào node Talos;
  - restart `libvirtd` hay `libvirt-guests`;
  - chạy lệnh nặng trên host2 (chỉ có một ổ HDD);
  - `git push` vào repo này, hay sửa tay trên GCP Console (GCP sửa qua Terraform).
- Kết quả ghi vào một file ghi chú, cuối ngày gửi Hưng. Hưng sẽ ghi vào nhật ký.

## Việc 0 – Bật host2 và kiểm cụm (08:30, 15 phút)

1. Bật host2, **đăng nhập portal công ty trên host2 (https)**. Chưa đăng nhập thì NTP bị chặn và Talos đứng chờ đồng bộ giờ.
2. Kiểm đồng hồ: `timedatectl | grep synchronized` phải ra `yes`. Hôm 23/11 host2 bật với giờ sai, xem nhật ký.
3. Chờ khoảng 10 phút để các VM tự bật, rồi kiểm (READ):
   ```bash
   ssh kvm-host2 'date +%T; export KUBECONFIG=~/talos-kvm/kubeconfig; kubectl get nodes; kubectl -n argocd get applications --no-headers | awk "{print \$2,\$3}" | sort | uniq -c; kubectl get pods -A --no-headers | grep -vE "Running|Completed"'
   ```
4. Ghi lại: node nào Ready (nhất là `w3`), bao nhiêu app Synced/Healthy, pod nào lỗi.

## Việc 1 – Kiểm w3 và KubeSpan (08:30–09:30, quan trọng nhất)

Mục tiêu: biết w3 đã về chưa. Nếu chưa, gom đủ bằng chứng để Hưng xử lý.

1. Trạng thái KubeSpan nhìn từ cp1 (READ):
   ```bash
   ssh kvm-host2 'date +%T; export TALOSCONFIG=~/talos-kvm/talosconfig; talosctl -e 10.10.10.11 -n 10.10.10.11 get kubespanpeerstatuses'
   ```
   Cột `STATE` của peer w3 phải là `up`, và cột `LAST HANDSHAKE` phải gần giờ hiện tại.
2. **Nếu w3 Ready và peer `up`:** chuyển sang việc 2.
3. **Nếu không:**
   - Chụp gói UDP 51820 trên host2 trong 20 giây, chỉ ghi số gói đi và về:
     ```bash
     ssh -t kvm-host2 'date +%T; sudo timeout 20 tcpdump -ni any -c 200 udp port 51820 2>&1 | tail -15'
     ```
     Khi dán vào chat thì xoá các IP công ty trong output đi.
   - Kiểm VM w3 trên GCP: `gcloud compute instances describe w3 --zone asia-southeast1-b --format="value(status)"`.
   - Ghi lại có gói trả về hay không, và cùng giờ đó mạng công ty có gì lạ không.
   - Không thử `reset` hay stop/start w3 nữa: hôm 23/11 làm hai lần đều không đỡ. Để Hưng quyết định.

## Việc 2 – Bù backup Keycloak và đưa cụm về bình thường (chỉ khi w3 đã Ready)

1. Kiểm app `monitoring` và `victoria-logs` đã Synced/Healthy chưa (lệnh của việc 0). Prometheus phải ở trên w3: `kubectl -n monitoring get pods -o wide | grep prometheus-kps`.
2. Kiểm Velero: `kubectl -n velero get deploy velero`.
   - Nếu `0/0`: Argo CD sẽ tự trả về 1 (selfHeal). Chờ 5 phút rồi kiểm lại.
   - Nếu vẫn 0 thì ghi lại, **không tự scale**.
3. **Chạy lại backup (CHANGE, đã được giao):**
   ```bash
   ssh -t kvm-host2 'date +%T; sudo systemctl start talos-etcd-backup.service; systemctl status talos-etcd-backup.service --no-pager | tail -5; date +%T'
   ```
   Sau đó kiểm kết quả:
   ```bash
   ssh kvm-host2 'date +%T; cat /var/lib/talos-backup/status.json'
   ```
   Mong đợi: etcd và Keycloak đều OK. Nếu `kc-backup` lại Pending thì xem `kubectl describe pod` phần Events, rồi ghi lý do.

## Việc 3 – Job image-scan 09:45 (10 phút, sau 10:00)

Đây là lần quét đầu tiên kể từ khi Argo CD lên v3.6.2.

1. `kubectl -n demo get jobs --sort-by=.metadata.creationTimestamp | tail -3`: job hôm nay Complete hay Failed.
2. Đọc dòng tóm tắt trong log (`critical_images=...`). Không chép cả log.
3. Nếu khác 0: ghi image, mã CVE, có bản vá chưa. Telegram sẽ có cảnh báo `ImageScanCritical`.

## Việc 4 – Chuẩn bị gia hạn CVE cho 27/11 (30 phút, chỉ đọc và soạn)

Đã chốt: 27/11 gia hạn 3 mục tới 31/12/2026 nếu chưa có bản vá. Xem [ke-hoach-cve-30-11.md](ke-hoach-cve-30-11.md).

1. Kiểm upstream qua GitHub API: Longhorn có 1.13.1 chưa, Talos có bản mới hơn v1.14.6 kèm flannel v0.28.11 chưa.
2. Chạy lại lệnh kiểm `/proc/*/maps` (mục 2 của file kế hoạch; lệnh đầy đủ Hưng gửi riêng). Mọi dòng phải là `: 0`.
3. Ghi kết quả để Hưng sửa `trivyignore.yaml` vào 27/11.

## Việc 5 – Tắt cụm cuối buổi (CHANGE, đã được giao)

Làm trước khi Phúc về. Thứ tự lệnh như sau:

```bash
ssh -t kvm-host2 'date +%T; ~/bin/talos-cluster-stop.sh; date +%T'
```

- Script tự backup nếu 30 phút gần nhất chưa có backup, rồi tắt w3, cp1, w1, w2.
- **Nếu script báo `LOI: backup that bai`:** không dùng `--skip-backup-check` ngay. Xem `journalctl -u talos-etcd-backup.service --since today | tail -30` rồi ghi lỗi. Chỉ khi backup ở việc 2 đã OK trong ngày thì mới được dùng `--skip-backup-check`.
- Sau khi 4 VM đã tắt (`virsh -c qemu:///system list` không còn VM chạy), tắt host2:
  ```bash
  ssh -t kvm-host2 'sudo poweroff'
  ```

## Cuối ngày

Gửi Hưng một tin gồm:
- trạng thái w3 và KubeSpan (kèm bằng chứng nếu vẫn hỏng);
- backup Keycloak đã OK chưa;
- kết quả image-scan;
- kết quả kiểm CVE;
- giờ tắt cụm;
- việc nào chưa làm và đang dừng ở bước nào.
