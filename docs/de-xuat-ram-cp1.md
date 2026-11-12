# Đề xuất: thêm RAM cho cp1, lấy từ w1

Người soạn: Hưng. Ngày 12/11/2026. Trạng thái: **chờ anh duyệt**. Chưa đổi gì trên host2 hay cụm.

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

## 6. Việc nhỏ kèm theo (duyệt riêng)

etcd DB 65 MB nhưng chỉ dùng 25 MB (39 %). Có thể chạy `talosctl -n 10.10.10.11 etcd defrag` một lần lúc cụm rảnh để bớt dung lượng đọc. Lệnh này khoá etcd vài giây, nên chỉ làm khi anh đồng ý và không có rollout nào đang chạy.
