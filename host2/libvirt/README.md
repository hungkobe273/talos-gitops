# libvirt trên host2

Khung của mạng và 3 VM cụm talos-kvm, lấy ngày 04/11/2026 bằng `virsh net-dumpxml --inactive`,
`virsh pool-dumpxml --inactive`, `virsh dumpxml --inactive`. Đã kiểm: bản `--security-info` giống hệt (không có
mật khẩu VNC), chỉ có IP `10.10.10.x` của lab.

| File | Nội dung |
|---|---|
| `talos-net.xml` | Mạng NAT `talos-net`, bridge `virbr-talos`, `10.10.10.1/24`, DHCP gán IP theo MAC (đuôi MAC trùng đuôi IP) |
| `pool-images.xml` | Pool `images` ở `/var/lib/libvirt/images` |
| `cp1.xml` | 2 vCPU, 3,5 GiB, đĩa `cp1.qcow2` (`cache=none`, `io=native`), ISO Talos còn gắn ở cdrom |
| `w1.xml`, `w2.xml` | 2 vCPU, 4,5 GiB, đĩa `w1.qcow2` / `w2.qcow2`; từ 06/11 thêm `vdb` = `w1-longhorn.qcow2` / `w2-longhorn.qcow2` (20G, dữ liệu Longhorn) |

Không đưa vào: `cp2`, `cp3` (tắt từ 20/10), mạng `default` (không dùng).

## Dựng lại khung (chạy trên host2, thứ tự quan trọng)

```bash
sudo virsh net-define talos-net.xml && sudo virsh net-autostart talos-net && sudo virsh net-start talos-net
sudo virsh pool-define pool-images.xml && sudo virsh pool-autostart images && sudo virsh pool-start images
for v in cp1 w1 w2; do sudo virsh define $v.xml && sudo virsh autostart $v; done
```

Đĩa không nằm trong Git. Mất đĩa Longhorn (`*-longhorn.qcow2`): tạo lại bằng `qemu-img create -f qcow2 ... 20G`, Longhorn tự dựng lại bản sao từ worker kia. Còn file qcow2 thì chỉ cần `define` rồi bật. Mất đĩa: tạo qcow2 mới
(`qemu-img create -f qcow2`), boot từ ISO `talos-v1.14.2-qga-amd64.iso`, áp machine config dựng từ
`secrets.yaml` trong bundle backup và các patch ở [talos/](../../talos/README.md).

Cấu hình host liên quan (không nằm trong XML): `/etc/default/libvirt-guests` để `ON_BOOT=ignore`,
`ON_SHUTDOWN=shutdown`; VM tự bật nhờ `autostart`.

## Cập nhật

Sau khi đổi RAM, CPU, đĩa hay mạng của VM: dump lại bằng lệnh trên, so `--security-info`, commit.