# Talos machine config patches

Bước 1 của [docs/de-xuat-iac.md](../docs/de-xuat-iac.md) (03/11/2026). Thư mục này chỉ chứa **patch**, không chứa
machine config đầy đủ. Machine config có secret của cụm (CA, token, khoá mã hoá etcd, `clusterSecret`) nên vẫn chỉ
nằm trên host2 (`~/talos-kvm/*.yaml`) và trong bundle backup mã hoá. Argo CD không đọc thư mục này.

Đã đối chiếu với cấu hình đang chạy trên cả 4 node ngày 03/11 (`talosctl get machineconfig`, chỉ so các document
không có secret): mọi giá trị khớp, kể cả hash CA trong `harbor-registry.yaml`.

## Patch nào áp cho node nào

| Patch | cp1 | w1 | w2 | w3 | Nội dung |
|---|---|---|---|---|---|
| `nodes/<node>.yaml` | x | x | x | x | IP tĩnh, gateway, VIP `10.10.10.100` (cp1), DNS công ty (để chỗ trống `COMPANY_DNS_1/2` vì repo public, giá trị thật ở `~/talos-kvm/patch-<node>.yaml` trên host2); w3: nhãn zone, taint `cloud=gcp:NoSchedule`, NTP của GCP |
| `etcd-timeout.yaml` | x | | | | etcd heartbeat 500 ms, election 5 s (HDD chậm, 15/10) |
| `authn-oidc.yaml` | x | | | | kube-apiserver tin ID token Keycloak cho Headlamp (22/10). Lùi: `rollback/authn-oidc-rollback.yaml` |
| `timesync-kvm.yaml` | x | x | x | | Đồng bộ giờ qua `/dev/ptp_kvm` (16/10) |
| `statichost-keycloak.yaml` | x | x | x | | `keycloak.talos.internal` → host2 (21/10) |
| `harbor-registry.yaml` | x | x | x | | `harbor.talos.internal` → host2, containerd tin CA nội bộ (27/10). Harbor đã bỏ 09/11: patch vẫn còn trên node, vô hại, gỡ sau (`--mode=no-reboot`) |
| `local-path.yaml` | | x | x | x | UserVolume cho local-path-provisioner (20/10) |
| `kubespan.yaml` | x | x | x | x | KubeSpan, MTU 1380, học thêm endpoint sau NAT (30/10) |
| `flannel-csum.yaml` | x | x | x | x | Tắt checksum offload trên `flannel.1` (VXLAN trong WireGuard, 30/10) |
| `longhorn.yaml` | | x | x | | `UserVolumeConfig` `longhorn` kiểu `disk` trên `/dev/vdb` (đĩa qcow2 20G riêng), mount `/var/mnt/longhorn` cho Longhorn (06/11) |

`statichost-keycloak.yaml` và `harbor-registry.yaml` cùng `name: 192.168.136.38`; Talos gộp `hostnames` theo thứ tự
áp (đang chạy: keycloak rồi harbor).

**Schematic (extension):** w1, w2 dùng [schematics/longhorn.yaml](schematics/longhorn.yaml) (ID `53513e54...`: qemu-guest-agent,
iscsi-tools, util-linux-tools) từ 06/11; cp1 và w3 vẫn schematic cũ `ce4c9805...` (chỉ qemu-guest-agent). Khi upgrade Talos
phải ghi rõ `--image factory.talos.dev/metal-installer/<ID>:<version>` đúng schematic của từng node. Document
`UnattendedInstallConfig` trong machine config của w1, w2 vẫn ghi image `ce4c9805...` (chỉ dùng khi cài lại node), cần
đổi sang `53513e54...` trước lần cài lại.

Không đưa vào: `patch-cp2.yaml`, `patch-cp3.yaml` (cp2, cp3 tắt từ 20/10, còn trong bundle backup),
`patch-kubespan.yaml` bản đầu (thay bằng bản có `harvestExtraEndpoints`).

## Cách dùng

**Patch là phần cộng thêm vào bản `talosctl gen config`, không áp lại nguyên bộ lên node đang chạy.** Talos gộp danh
sách bằng cách nối thêm: dry-run 03/11 áp cả bộ lên 4 node cho 0 dòng xoá hoặc đổi, nhưng nhân đôi các phần tử danh
sách đã có (IP, route, DNS, `/dev/ptp_kvm`, hostname). Khi sửa node đang chạy, chỉ áp patch của document vừa đổi; nếu
document có danh sách thì xem dry-run để chắc không bị lặp.

Sửa một patch:
1. Sửa file ở đây, commit (chưa push nếu chưa thử).
2. Thử, không ghi gì lên node (chạy trên host2, `TALOSCONFIG=~/talos-kvm/talosconfig`):
   `talosctl -n <ip> patch mc --patch @talos/patches/<file>.yaml --dry-run`
   Không dùng `apply-config --insecure`. Lọc output, không in secret.
3. Áp: bỏ `--dry-run`, thêm `--mode=no-reboot` nếu thay đổi cho phép. Ghi `docs/nhat-ky-thay-doi.md`, push.
4. Chép lại machine config mới về `~/talos-kvm/<node>.yaml` (bản cũ đổi tên `.bak-<ngày>`), để bundle backup có bản mới.

Dựng lại một node từ đầu (ví dụ khôi phục): `talosctl gen config` với `secrets.yaml` lấy từ bundle backup, rồi
`--config-patch @talos/patches/...` theo bảng trên. Cụm diễn tập Velero dùng secret cụm mới, không dùng bộ patch này.
