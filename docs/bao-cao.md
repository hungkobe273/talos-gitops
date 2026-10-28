# Báo cáo hiện trạng lab Kubernetes HA (cụm talos-kvm)

Người thực hiện: Hưng, Phúc. Cập nhật: 16/10/2026.

File này là báo cáo tổng hợp, cập nhật mỗi khi có thay đổi lớn. Chi tiết từng thay đổi theo ngày ở [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md); sơ đồ ở [kien-truc.md](kien-truc.md); link Grafana, Headlamp ở [truy-cap.md](truy-cap.md).

## Tóm tắt

- Cụm 3 control plane + 2 worker chạy trên một máy KVM (kvm-host2 `192.168.136.38`), API qua VIP `10.10.10.100:6443`.
- Đã có GitOps (Argo CD, app-of-apps), CI/CD cho app mẫu (GitHub Actions, GHCR private), giám sát và cảnh báo về Telegram, backup etcd tự động hằng ngày có cảnh báo khi lỗi.
- Nút thắt lớn nhất là ổ HDD duy nhất: đã gây 2 lần API cụm gián đoạn (15/10 và 16/10). Đề xuất chính: xin SSD cho đĩa VM.

## 1. Mục tiêu

Dựng một cụm Kubernetes có tính sẵn sàng cao và vận hành theo cách làm của môi trường production:

- Control plane HA: 3 node etcd, API server sau một địa chỉ VIP.
- Triển khai bằng GitOps, ứng dụng có pipeline CI/CD từ commit đến cụm.
- Không để lộ secret trong Git, phân quyền truy cập rõ ràng.
- Có giám sát, cảnh báo, quy trình vận hành hằng ngày và backup.

## 2. Kiến trúc

Sơ đồ hạ tầng, luồng GitOps, giám sát và bảng phiên bản: [kien-truc.md](kien-truc.md).

Tóm tắt: Talos v1.14.2, Kubernetes v1.37.1, Flannel, KubePrism, VIP Layer 2. 5 VM (CP 2 vCPU/2 GB, worker 2 vCPU/3 GB) trên mạng NAT `10.10.10.0/24` của kvm-host2 (i7-6700, 16 GB, 1 HDD). Argo CD v3.5.4 đồng bộ 4 ứng dụng: sealed-secrets, monitoring (kube-prometheus-stack), demo-app, headlamp.

## 3. Bảo mật

**Secret**

- Secret trong Git chỉ ở dạng SealedSecret (mã hóa, chỉ controller trong cụm giải được): token bot Telegram, tài khoản admin Grafana, credential kéo image GHCR.
- Khóa giải mã của Sealed Secrets đã được backup.
- File nhạy cảm của cụm (secret Talos, talosconfig, kubeconfig, snapshot etcd) chỉ nằm trên host2 trong thư mục quyền 700, không commit vào Git, không in ra màn hình hay chat.
- Token cho cảnh báo backup trên host2 nằm trong file root 600; dịch vụ gửi tin chạy user tạm (DynamicUser) và nhận token qua LoadCredential.

**Phân quyền và cô lập**

- Pod Security Admission: `demo` và `headlamp` ở mức restricted; `monitoring` privileged (node-exporter cần quyền host).
- Headlamp: đã tắt binding cluster-admin mặc định của chart; 2 tài khoản `headlamp-admin` và `headlamp-viewer` (chỉ xem, không đọc Secret); đăng nhập bằng token ngắn hạn 8 giờ.
- Argo CD đọc repo bằng deploy key chỉ đọc; CI dùng deploy key riêng có quyền ghi để sửa tag. Image GHCR private, kéo bằng PAT chỉ có quyền `read:packages`, hạn 90 ngày.
- UI chưa mở ra LAN, hiện chỉ truy cập qua SSH tunnel.

Bài học 14/10: một lệnh dry-run ở maintenance mode in toàn bộ config kèm secret. Đã reset cụm, tạo bộ secret mới và đưa lệnh đó vào danh sách cấm.

## 4. Vận hành hằng ngày và backup

Host2 bị tắt khoảng 17:00 mỗi ngày nên cụm được bật/tắt có kiểm soát theo runbook.

**Buổi sáng**

1. Đăng nhập captive portal trên host2 (cần cho Internet, kéo image, gửi Telegram).
2. Kiểm tra host: giờ, RAM, áp lực IO (PSI).
3. Kiểm tra 5 VM, etcd 3 member cùng leader, 5 node Ready, Argo CD Synced/Healthy.
4. Kiểm tra backup etcd hôm trước và các cảnh báo đang firing.

**Buổi chiều**

1. 16:45 backup tự động; khoảng 16:50 xác nhận log.
2. Tắt 2 worker, chờ `shut off`.
3. Tắt 3 CP cùng lúc (tắt lần lượt sẽ làm etcd bầu leader liên tục).
4. Nếu quên, libvirt-guests tự tắt VM khi host tắt; sáng hôm sau VM tự bật.

**Backup etcd**

| Hạng mục | Chi tiết | Trạng thái |
|---|---|---|
| Lịch | systemd timer 16:45 hằng ngày, `Persistent=false` (lúc host mới bật etcd chưa sẵn sàng) | Đã chạy thử |
| Script | Chụp snapshot qua talosctl, thử lần lượt cp1, cp2, cp3; giữ 7 bản; file chmod 600 | Chạy tay và qua systemd OK |
| Cảnh báo lỗi | OnFailure gửi Telegram kèm 5 dòng log cuối | Giả lập lỗi, tin về sau ~1 s |
| Lần chạy tự động đầu tiên | 16:45 ngày 16/10 | Chưa kiểm chứng |
| Khôi phục từ snapshot | `talosctl bootstrap --recover-from` | Chưa diễn tập |

## 5. Sự cố đã gặp và bài học

| Thời điểm | Sự cố | Xử lý và bài học |
|---|---|---|
| 14/10 | Lệnh dry-run ở maintenance mode in config kèm secret | Reset cụm, tạo secret mới. Cấm lệnh này; xem Secret chỉ theo tên khóa. |
| 15/10 sáng | Host thiếu RAM, dùng swap; etcd bầu leader liên tục | Giảm RAM CP 2560 → 2048 MB, swappiness 10, nới timeout etcd. Gốc là HDD (khoảng 33 fsync/s từ 3 etcd). |
| 15/10 14:14 | Grafana limit 256Mi thrash page cache, đọc đĩa 23–40 MB/s, IO 30%, cả 3 apiserver unready | Nâng Grafana lên 512Mi; gỡ rollout bị kẹt bằng cách scale ReplicaSet cũ về 0. |
| 16/10 sáng | Portal hết hạn, host mất Internet; Talos chờ đồng bộ giờ mãi nên etcd không chạy, không có VIP | Cụm lấy giờ từ host2 qua KVM PTP, `bootTimeout` 2 phút; host2 đổi NTP sang Cloudflare. |
| 16/10 10:34–10:45 | Grafana chạm limit 512Mi, đọc lại đĩa liên tục, HDD nghẽn, API cụm gián đoạn | Nâng Grafana lên request 384Mi / limit 1Gi (commit `3bc3f8e`). Chi tiết bên dưới. |

**Chi tiết sự cố 16/10 10:34–10:45**

1. Container Grafana trên w1 tăng working set 237 → 475 MiB, sát limit 512Mi.
2. Kernel ép page cache của cgroup từ 255 → 65 MiB, Grafana phải đọc lại đĩa, trung bình khoảng 50 MB/s trong 5 phút.
3. HDD nghẽn: PSI io full 62–72% trên host2.
4. etcd fdatasync lên 2 s, VIP API mất tạm thời, probe timeout toàn cụm.
5. kube-apiserver restart 1–2 lần mỗi CP, controller-manager và scheduler 3–5 lần.
6. Cụm tự hồi phục khi liveness probe kill Grafana.

Rollout bản sửa (11:08–11:17) cũng gây tải: pod mới trên w2 kéo image 464 MB và chạy lại migration DB của Grafana, PSI io lên 55% và control plane restart thêm. Grafana hiện chạy trên w2.

Cách điều tra: PSI của host2, `virsh domblkstat` theo từng VM, `vmstat`, Prometheus `query_range` theo container; đã loại trừ snap/apt trên host.

Bài học: HDD đang sát trần IOPS (khoảng 52 fsync/s chỉ riêng 3 etcd), nên một container thrash ở worker cũng kéo sập control plane. Hai sự cố 15/10 và 16/10 có cùng gốc. Ngoài ra host2 chưa có giám sát riêng nên phải điều tra tay.

## 6. Giới hạn hiện tại

- **Một ổ HDD cho cả cụm.** PSI io của host2 lúc bình thường 10–25%, khi sự cố lên 62–72%. Đây là giới hạn chính về độ ổn định.
- **Một máy vật lý.** 5 VM cùng nằm trên host2, nên HA chỉ chống được lỗi VM/node, không chống được lỗi host hay ổ đĩa.
- **Backup chưa có bản ngoài host2.** Snapshot etcd và backup khóa Sealed Secrets nằm cùng ổ HDD với VM. Chưa diễn tập khôi phục.
- **Lịch tắt máy 17:00.** Nếu host tắt trước 16:45 thì hôm đó không có backup tự động (phải chụp bù tay). Mỗi sáng phải đăng nhập portal tay.
- **host2 chưa được giám sát.** Prometheus chỉ thu metrics 5 node Talos, không có cảnh báo cho IO/RAM của host.
- **RAM sát.** 12/16 GB đã cấp cho VM; sáng 15/10 từng phải giảm RAM CP vì host swap.
- **sudo không mật khẩu.** User quản trị trên host2 đang đặt NOPASSWD (từ 16/10) cho tiện thao tác lab; đánh đổi bảo mật, cần thu hồi khi kết thúc giai đoạn dựng.
- **PAT kéo image hạn 90 ngày.** Cần gia hạn trước khi hết hạn, nếu không pod mới của demo-app sẽ không kéo được image.
- **Grafana, Headlamp chưa mở ra LAN.** Hiện phải có tài khoản SSH trên host2 mới vào được.

## 7. Việc tiếp theo và đề xuất

| Ưu tiên | Việc | Lý do |
|---|---|---|
| Cao | Xin SSD cho đĩa VM (cần anh duyệt) | Giải quyết gốc của 2 sự cố API; etcd cần độ trễ fsync thấp, HDD đang ở mức 33–52 fsync/s và PSI io 10–25% lúc bình thường. |
| Cao | Mở Grafana, Headlamp cho máy trong LAN `192.168.136.x` | Anh theo dõi trực tiếp bằng link, không cần SSH. |
| Cao | Kiểm chứng lần backup tự động 16:45 | Chưa xác nhận lần chạy tự động đầu tiên. |
| Cao | Đưa bản backup etcd và khóa Sealed Secrets ra ngoài host2 | Hiện mất ổ HDD là mất cả cụm lẫn backup. |
| Trung bình | Diễn tập khôi phục etcd từ snapshot (cùng anh) | Backup chưa thử khôi phục thì chưa thể tin cậy. |
| Trung bình | Giám sát host2 (CPU, RAM, PSI io) và cảnh báo về Telegram | Phát hiện nghẽn IO sớm thay vì điều tra tay sau sự cố. |
| Trung bình | Thử tắt w2: cảnh báo node down, pod chuyển sang w1 | Kiểm chứng HA ở tầng worker và đường cảnh báo. |
| Thấp | Thu hồi sudo NOPASSWD; quy trình cấp quyền Headlamp chỉ xem cho thành viên nhóm | Đưa cấu hình về gần production. |
