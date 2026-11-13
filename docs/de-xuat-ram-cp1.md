# Đề xuất: thêm RAM cho cp1, lấy từ w1

Người soạn: Hưng. Ngày 12/11/2026. Trạng thái: **ĐÃ ĐỔI 12/11 15:16** lúc cụm tắt (cp1 và w1 cùng 4194304 KiB, w2 giữ nguyên). Đo lại sau cold start 13/11 và sau 1 tuần (mục 7).

## 1. Vấn đề

cp1 là control plane duy nhất (etcd, kube-apiserver, controller-manager, scheduler) và đang có ít RAM nhất cụm. Sáng 12/11, lúc Argo CD áp cert-manager v1.21.3, ba thành phần control plane cùng khởi động lại:

| Pod | Restart | Lần gần nhất (giờ VN) | Lý do |
|---|---|---|---|
| kube-apiserver | 1 | 09:06:34 | Error |
| kube-scheduler | 2 | 09:07:15 | Error |
| kube-controller-manager | 2 | 09:07:16 | Error |

apiserver chết vì etcd trả lời chậm; scheduler và controller-manager mất leader lease theo sau. Cụm tự hồi trong khoảng 1 phút, không mất dữ liệu, nhưng trong khoảng đó API không trả lời nên `kubectl` và Argo CD không làm việc được.

## 2. Số liệu (12/11, 09:29, cụm đã chạy 1 giờ)

| | cp1 | w1 | w2 |
|---|---|---|---|
| RAM VM (libvirt) | 3.5 GiB | 4.5 GiB | 4.5 GiB |
| Kernel thấy (MiB) | 3394 | 4396 | 4396 |
| Đang dùng (MiB) | 2173 | 1698 | 1767 |
| Page cache (MiB) | 1011 | 2557 | 2456 |
| Còn dùng được (MiB) | **916** | 2399 | 2323 |
| PSI io `some` avg300 | **21.65 %** | 2.47 % | |
| PSI memory `some` avg300 | 0.02 % | 0 % | |
| Request memory của pod / allocatable | 1168 Mi / 2782 Mi (41 %) | 2748 Mi / 3913 Mi (70 %) | 2356 Mi / 3913 Mi (60 %) |

Trên cp1, riêng kube-apiserver chiếm 1.6 GB RSS, gần nửa RAM; etcd 131 MB, controller-manager 160 MB. Lúc 09:10 (ngay sau lần restart) cp1 còn 1366 MiB, đến 09:29 còn 916 MiB vì apiserver dựng lại cache.

Đọc số liệu:

- cp1 chưa bị OOM, áp lực RAM gần 0. Chỗ nghẽn là **đĩa**: 21 % thời gian có tiến trình chờ IO, gấp gần 9 lần w1.
- Page cache của cp1 chỉ khoảng 1 GiB, nên etcd và apiserver phải đọc lại từ đĩa nhiều hơn. host2 chỉ có một ổ HDD dùng chung cho cả 3 VM, nên mỗi lần đọc lại là tranh đĩa với Longhorn trên w1, w2.
- Ngày 10/11 đã thử ưu tiên đĩa cho cp1 bằng BFQ trên host2 và không đạt ([de-xuat-bfq.md](de-xuat-bfq.md), mục 7). Thêm RAM để có thêm page cache là cách tiếp theo, không phải đụng Talos.

## 3. Đề xuất

host2 có 16 GB và đã gần hết: `free -m` lúc 09:28 còn 1796 MiB available, nên **không cấp thêm từ host** mà chuyển 512 MiB từ w1 sang cp1. Tổng RAM cấp cho VM giữ nguyên 12.5 GiB.

| VM | Hiện tại | Sau khi đổi |
|---|---|---|
| cp1 | 3.5 GiB (3670016 KiB) | **4 GiB** (4194304 KiB) |
| w1 | 4.5 GiB (4718592 KiB) | **4 GiB** (4194304 KiB) |
| w2 | 4.5 GiB | giữ nguyên |

Vì sao lấy từ w1:

- w1 còn 2399 MiB dùng được, sau khi bớt 512 MiB vẫn còn khoảng 1.9 GiB.
- Request của pod trên w1 sẽ lên khoảng 2748 / 3400 Mi (81 %), vẫn dưới 100 % nên không pod nào bị đẩy ra. Pod lớn nhất trên w1 là Grafana (896 Mi).
- Phương án khác: lấy 256 MiB từ mỗi worker (w1, w2 cùng 4.25 GiB). Cân hơn nhưng phải sửa 3 VM thay vì 2.

Lợi ích mong đợi: cp1 có thêm khoảng 500 MiB cho page cache, tức gấp rưỡi hiện tại. Không chắc hết hẳn restart, vì ghi etcd (fsync) vẫn phụ thuộc HDD; sẽ đo lại PSI io và đếm restart sau một tuần.

## 4. Cách làm (Hưng chạy, chỉ khi cụm đã tắt)

Làm lúc VM đã tắt, sau `~/bin/talos-cluster-stop.sh` buổi chiều hoặc trước khi bật cụm buổi sáng. Không đổi RAM lúc VM đang chạy, không khởi động lại libvirtd.

```bash
date +%T; virsh -c qemu:///system list --all   # cp1, w1, w2 phải "shut off"
# cp1: tăng max trước rồi mới tăng current
virsh -c qemu:///system setmaxmem cp1 4194304 --config
virsh -c qemu:///system setmem    cp1 4194304 --config
# w1: giảm current trước rồi mới giảm max
virsh -c qemu:///system setmem    w1 4194304 --config
virsh -c qemu:///system setmaxmem w1 4194304 --config
virsh -c qemu:///system dominfo cp1 | grep -i memory
virsh -c qemu:///system dominfo w1  | grep -i memory
```

Sau đó sửa `host2/libvirt/cp1.xml` và `host2/libvirt/w1.xml` trong repo cho khớp, ghi nhật ký.

Kiểm tra sau khi bật cụm:

- `talosctl -n 10.10.10.11,10.10.10.21 memory`: cp1 TOTAL khoảng 3900 MiB, w1 khoảng 3900 MiB.
- `kubectl get node -o custom-columns=NAME:.metadata.name,ALLOC:.status.allocatable.memory`
- Không pod nào Pending trên w1.
- Sau 1 tuần: PSI io của cp1 và số restart của apiserver so với bảng ở mục 2.

## 5. Đường lùi

Chạy lại lúc VM tắt, với giá trị cũ (cp1 giảm current trước, w1 tăng max trước):

```bash
virsh -c qemu:///system setmem    cp1 3670016 --config
virsh -c qemu:///system setmaxmem cp1 3670016 --config
virsh -c qemu:///system setmaxmem w1 4718592 --config
virsh -c qemu:///system setmem    w1 4718592 --config
```

File XML gốc có sẵn trong `host2/libvirt/` (giá trị hiện tại), dùng được để `virsh define` lại nếu cần.

## 6. Việc nhỏ kèm theo (làm sau khi đổi RAM)

etcd DB 65 MB nhưng chỉ dùng 25 MB (39 %). Có thể chạy `talosctl -n 10.10.10.11 etcd defrag` một lần lúc cụm rảnh để bớt dung lượng đọc. Lệnh này khoá etcd vài giây, nên chỉ làm khi không có rollout nào đang chạy, sau khi cp1 đã có 4 GiB.

## 7. Kết quả

- 12/11 15:11: lưu log etcd mốc (`~/talos-kvm/etcd-log-20261112.txt`, 2476 dòng). 15:13 backup đủ (etcd, Keycloak, Vault, bundle B2 + GCS). 15:16:22 cụm tắt bằng stop script, 15:16:39 đổi RAM: cp1, w1 4194304 KiB; w2 4718592 KiB.
- 13/11 09:14 (cụm bật 08:39, chạy 35 phút; mốc 12/11 đo lúc cụm chạy 1 giờ):

  | | 12/11 09:29 | 13/11 09:14 |
  |---|---|---|
  | cp1 kernel thấy (MiB) | 3394 | 3898 |
  | cp1 page cache (MiB) | 1011 | 1376 |
  | cp1 còn dùng được (MiB) | 916 | **1443** |
  | cp1 PSI io `some` avg300 | 21.65 % | **21.84 %** |
  | cp1 PSI memory `some` avg300 | 0.02 % | 0 % |
  | w1 còn dùng được (MiB) | 2399 | 1985 |
  | Pod Pending | 0 | 0 |

  kube-apiserver 0 restart; scheduler và controller-manager mỗi cái 3 restart, cùng lúc 08:41:05 (2 phút sau khi bật cp1, lúc apiserver chưa sẵn sàng nên mất lease), là kiểu restart lúc khởi động, không phải loại 12/11.
- Đọc: RAM đạt mục tiêu (cp1 thêm khoảng 530 MiB dùng được, page cache thêm 365 MiB, w1 vẫn dư gần 2 GiB). **PSI io không đổi**, nên chỗ chờ đĩa của cp1 không do đọc lại vì thiếu cache mà chủ yếu do ghi (fsync của etcd) trên HDD dùng chung. Hướng tiếp nếu còn restart: đo `etcd_disk_wal_fsync_duration_seconds`, cân nhắc `etcd defrag` (mục 6) hoặc đặt đĩa cp1 riêng.
- 13/11 09:16, đo ghi của etcd. Prometheus không scrape etcd (không có job etcd), nên đếm cảnh báo trong `talosctl logs etcd`:

  | Cửa sổ log | Dài | `slow fdatasync` (>1 s) | `apply request took too long` (>100 ms) | Trung bình | >500 ms | >1 s | Max |
  |---|---|---|---|---|---|---|---|
  | 12/11 14:29–15:11 (cụm chạy ổn định) | 42 phút | 0 | 565 | 145 ms | 0 | 0 | 468 ms |
  | 13/11 08:47–09:16 (sau cold start) | 29 phút | 0 | 581 | 204 ms | 32 | 6 | 1258 ms |
  | 13/11 09:37–09:59 (sau 2 thay đổi dưới) | 22 phút | 0 | 319 | 161 ms | 8 | 1 | 1179 ms |

  Giữa hai cửa sổ: descheduler `*/10` → `*/30` (09:25) và lease argo-rollouts 15/10/2 s → 60/45/15 s (09:36). Ghi chậm mỗi phút 20 → 14,5 (−27 %); lần > 1 s 6 → 1; lease argo-rollouts trong ghi chậm còn 1 lần (trước khoảng 1 lần/phút). PSI io cp1 avg300 21,8 % → 19,6 %. Một phần có thể do Longhorn rebuild và truy vấn Prometheus buổi sáng đã xong, nên chưa tách được riêng phần của từng thay đổi.

  Chưa có lần fsync nào quá 1 s, nhưng khoảng 20 lần ghi chậm mỗi phút và sáng nay chậm hơn chiều qua. Hai cửa sổ không cùng điều kiện: sáng nay có Longhorn rebuild sau cold start và truy vấn Prometheus 7 ngày (thử rule obs1), cả hai cùng ổ HDD. Đỉnh rơi vào 08:50, 09:00, 09:10 (chu kỳ 10 phút, chưa rõ job nào). Muốn có histogram fsync thật cần cho etcd mở metrics (`listen-metrics-urls` trong machine config cp1) và bật `kubeEtcd` trong kps: đổi cấu hình Talos, cần anh duyệt.
- Cần đo tiếp: sau 1 tuần (20/11) đếm restart kube-apiserver và PSI io lúc cụm chạy ổn định.
