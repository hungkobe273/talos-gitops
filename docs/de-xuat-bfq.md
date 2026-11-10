# Đề xuất: ưu tiên đĩa cho cp1 bằng BFQ trên host2

Người soạn: Hưng. Ngày 10/11/2026. Trạng thái: **đã thử 10/11 09:19–09:50, KHÔNG đạt, đã lùi** (kết quả ở mục 7). Không đụng Talos, không khởi động lại VM hay
libvirtd.

## 1. Vấn đề

Cả 3 VM (cp1, w1, w2) nằm chung **một ổ HDD** trên host2 (WD10EZEX 1 TB, 7200 vòng). HDD chỉ có một đầu đọc: mỗi lần
nhảy vị trí mất khoảng 10 ms, đọc ghi ngẫu nhiên được khoảng 100–150 thao tác mỗi giây cho **cả máy**.

etcd trên cp1 phải `fsync` WAL xong thì mới trả lời API. Khi w1, w2 đang ghi nhiều (kéo image, Longhorn đồng bộ
replica, Prometheus) hoặc chính host2 ghi (apt), lệnh `fsync` của cp1 phải xếp hàng sau.

Số đo 10/11:

| Mục | Giá trị |
|---|---|
| Cold start các sáng gần đây | API mất khoảng 25 giây vì etcd trên cp1 trượt health check |
| Log etcd cp1, 08:47–09:11 (lúc cụm đã xanh, chưa làm gì) | 582 dòng `apply request took too long` (ngưỡng 100 ms), chậm nhất **1,42 s** |
| `sda` lúc 09:12 | 277 đọc/s, 92 ghi/s, thời gian chờ ghi 10,4 ms, bận 75% |
| PSI io host2 | `some avg60` 6–18% |
| Ai đang ghi lúc 09:12 | `unattended-upgrades` **24 MB/s**, systemd 7,7 MB/s; 3 VM cộng lại khoảng 200 KB/s |

Phát hiện phụ: host2 tắt qua đêm nên `apt-daily.timer` và `apt-daily-upgrade.timer` (`Persistent=true`) chạy bù
**ngay sau khi bật máy**. Sáng 10/11: `apt-daily` lúc 08:32:50 (3 phút sau boot, giữa cold start),
`apt-daily-upgrade` lúc 09:10:36. Đúng hai lúc này log etcd dày nhất.

## 2. BFQ là gì

I/O scheduler là tầng trong kernel quyết định yêu cầu đọc ghi nào được đưa xuống đĩa trước.

- **mq-deadline** (host2 đang dùng): xếp theo vị trí trên đĩa, mỗi yêu cầu có hạn chót (đọc 0,5 s, ghi 5 s). Nó
  **không biết** yêu cầu đến từ VM nào. Ai gửi nhiều thì chiếm nhiều.
- **BFQ** (Budget Fair Queueing): chia **thời gian dùng đĩa** cho từng tiến trình hoặc cgroup theo **trọng số**,
  ưu tiên yêu cầu đồng bộ cần độ trễ thấp (như `fsync` của etcd). Mỗi VM libvirt là một cgroup riêng
  (`machine-qemu-...-cp1.scope`), nên đặt được "cp1 nặng gấp 10 lần w1, w2".

Hiện nay libvirt đã đặt blkio weight 100 cho cả 3 VM, nhưng **mq-deadline bỏ qua trọng số**: con số này không có tác dụng.
BFQ có sẵn trong kernel host2 (`CONFIG_IOSCHED_BFQ=m`, `CONFIG_BFQ_GROUP_IOSCHED=y`), chỉ cần nạp module.

Vì sao làm trên host2 mà không làm trong cp1: trong cp1 chỉ thấy một ổ `vda` của riêng nó (scheduler `none`), không
thấy w1, w2 đang tranh đĩa. Hàng đợi thật nằm ở `sda` của host2.

## 3. Đề xuất

Tất cả trên host2, Hưng chạy, không khởi động lại gì.

| Bước | Việc | Lệnh chính |
|---|---|---|
| 1 | Nạp BFQ, đổi scheduler `sda` | `modprobe bfq; echo bfq > /sys/block/sda/queue/scheduler` |
| 2 | cp1 trọng số 1000, w1/w2 hạ xuống 20 (xem ghi chú dưới bảng) | `virsh blkiotune cp1 --weight 1000 --live --config`, `virsh blkiotune w1 --weight 20 ...` |
| 3 | apt chạy ở mức ưu tiên đĩa thấp nhất | drop-in `IOSchedulingClass=idle`, `IOWeight=10` cho `apt-daily.service`, `apt-daily-upgrade.service` |
| 4 | Giữ qua reboot | `/etc/modules-load.d/bfq.conf`, udev rule chọn BFQ cho ổ quay |

Ghi chú bước 2 (gặp khi làm 10/11): trên cgroup v2, libvirt đặt `IOWeight` qua systemd, systemd đổi sang thang BFQ:
dưới 100 giữ nguyên, trên 100 thì `100 + (w - 100) * 900 / 9900`. `--weight 1000` chỉ ra `io.bfq.weight` **181**,
gấp 1,8 lần w1/w2 (100). Vì vậy hạ w1, w2 xuống 20: cp1 181 so với 20, gấp khoảng 9 lần.

File đưa vào Git (`host2/`):

```
# host2/udev/60-iosched.rules
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"

# host2/modules-load/bfq.conf
bfq

# host2/systemd/apt-daily.service.d/20-io-idle.conf (cùng nội dung cho apt-daily-upgrade.service.d/)
[Service]
IOSchedulingClass=idle
IOWeight=10
```

`IOSchedulingClass=idle` chỉ có tác dụng với BFQ (mq-deadline bỏ qua), nên bước 3 đi cùng bước 1. Không tắt
unattended-upgrades, vẫn cập nhật bảo mật, chỉ là nhường đĩa.

Trọng số 1000 không làm w1, w2 đói đĩa: trọng số chỉ có tác dụng khi đang tranh, cp1 ghi ít (khoảng 80 KB/s), phần còn
lại vẫn cho w1, w2.

## 4. Đo trước và sau

| Chỉ số | Cách đo | Trước (10/11) | Mong đợi |
|---|---|---|---|
| Log chậm etcd | đếm `took too long` trong `talosctl -n cp1 logs etcd` mỗi 30 phút | 582 / 25 phút, chậm nhất 1,42 s | giảm rõ, chậm nhất dưới 0,5 s |
| API khi cold start | `coldstart-watch` | mất khoảng 25 s | không mất |
| Thời gian chờ `sda` | `/proc/diskstats` 15 s | ghi 10,4 ms | tương đương (BFQ không làm đĩa nhanh hơn, chỉ chia lại) |
| Cold start tổng | `coldstart-watch` | xanh +9:10, Grafana +8:55 | không chậm hơn |

Kế hoạch: làm bước 1–3 hôm nay (T3 10/11), đo 30 phút, bước 4 sau khi số đo đạt. Cold start sáng 11/11 là lần đo
chính.

## 5. Rủi ro và lùi

- Tổng thông lượng HDD có thể giảm vài phần trăm (BFQ nhường thời gian cho yêu cầu đồng bộ). CPU thêm không đáng kể ở
  mức vài trăm thao tác mỗi giây.
- Workload ghi nhiều trên w1, w2 (Longhorn rebuild) có thể chậm hơn khi cp1 đang ghi. Theo dõi PSI và Longhorn sau
  khi đổi.
- Lùi ngay, không khởi động lại:
  `echo mq-deadline > /sys/block/sda/queue/scheduler; virsh blkiotune cp1 --weight 100 --live --config`,
  xoá drop-in apt, udev rule, modules-load.

## 6. Không làm

- Không bật BFQ trong Talos (cp1 không thấy hàng đợi thật, xem mục 2).
- Không tắt unattended-upgrades, không đổi lịch apt (máy tắt qua đêm nên lịch nào cũng chạy bù sau boot).
- Không thêm scrape metrics etcd vào Prometheus đợt này (cần sửa `listen-metrics-urls` của Talos): đo bằng log là đủ.
  Có thể làm sau nếu cần biểu đồ.

## 7. Kết quả thử 10/11

Bật BFQ 09:17, cp1 weight 1000 (`io.bfq.weight` 181), w1/w2 20 lúc 09:19, apt idle. Đếm dòng `took too long` trong log
etcd cp1 theo 10 phút:

| Khoảng | Scheduler | Dòng chậm |
|---|---|---|
| 08:50–08:59 | mq-deadline | khoảng 100 |
| 09:00–09:09 | mq-deadline | 142 |
| 09:20–09:29 | BFQ | 120 |
| 09:30–09:39 | BFQ | 253 (apiserver readiness 500 x16) |
| 09:40–09:49 | BFQ | 135 |

Chậm nhất: trước 1,42 s, sau 3,54 s; 60 request từ 0,5 s trở lên trong 30 phút sau khi bật. apt không chạy trong lúc đo.
Không cải thiện, có dấu hiệu xấu hơn → lùi về mq-deadline, weight 100. Phỏng đoán (chưa kiểm): BFQ idling trên HDD
chờ thêm request của cùng một tiến trình qemu, làm `fsync` của cp1 chờ lâu hơn. Drop-in apt giữ lại (vô hại với
mq-deadline). Không cài udev rule, modules-load.
