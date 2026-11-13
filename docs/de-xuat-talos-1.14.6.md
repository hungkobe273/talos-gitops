# Đề xuất: nâng Talos v1.14.2 lên v1.14.6

Người soạn: Hưng. Ngày 13/11/2026. Trạng thái: **w2, w1 đã nâng 13/11 (14:07–14:20); còn w3, cp1**. Kubernetes giữ nguyên 1.37.1.

## 1. Tóm tắt

Bốn bản vá 1.14.3–1.14.6 (15/10–11/11) cùng nhánh, không đổi cấu hình bắt buộc. Lợi ích chính:

- kernel 6.18.5x → 6.18.63 và Go 1.26.9 → 1.26.11 (vá bảo mật);
- etcd 3.7.1 → 3.7.3 (sửa data race);
- sửa lỗi KubePrism tự hồi sau khi apiserver chết.

**Không** vá được CVE-2026-111497 của flannel: flannel v0.28.10 đi kèm 1.14.6 vẫn có brotli-libs 1.2.0-r1 (Trivy 13/11). Mục đó trong `trivyignore.yaml` vẫn giữ. Timer `talos-upstream-check` trên host2 lấy mốc v1.14.6 để báo bản sau.

## 2. Thay đổi liên quan tới cụm

| Bản | Thay đổi | Liên quan tới mình |
|---|---|---|
| 1.14.3 | `fix: improve KubePrism load balancer recovery` | **Có.** kubelet và pod trên node đi qua KubePrism (localhost:7445) tới apiserver. apiserver cp1 đã chết 06/11, 10/11, 12/11; hồi nhanh hơn thì đỡ restart theo |
| 1.14.3, 1.14.5 | etcd 3.7.1 → 3.7.2 → 3.7.3 | **Một phần.** Sửa data race `Hash`/`Restore` và `RangeStream`. Lỗi hiệu năng `MsgApp` và fsync snapshot chỉ ảnh hưởng cụm nhiều member, cụm mình có 1 member |
| 1.14.3–1.14.6 | Linux 6.18.56 → 6.18.63, containerd 2.3.7, Go 1.26.11 | **Có.** Vá bảo mật kernel và Go |
| 1.14.5 | `fix: route pod CIDRs matching the KubeSpan ULA purpose byte` | Có thể có (KubeSpan tới w3), nhưng pod CIDR của mình là IPv4 10.244/16, không trùng ULA IPv6. Ít khả năng |
| 1.14.5 | `fix: pull images over HTTP/1.1` | Có thể giúp kéo image ổn định hơn qua portal công ty |
| 1.14.5 | `fix: provide proper concurrency for health checks` | Có (`talosctl health`, dùng lúc cold start) |
| 1.14.6 | `fix: use aescbc provider for AES-CBC key in etcd encryption config` | **Không:** chỉ cụm tạo trước Talos 1.3 hoặc chuyển từ kubeadm. Cụm mình tạo trên 1.14 (10/2026) |
| 1.14.3 | `TimeService/TimeCheck` không còn cho role `os:reader` | Không: host2 dùng talosconfig `os:admin` |
| 1.14.3 | `fix: disable GSO offload on QEMU 10.2+` | Không: host2 chạy QEMU 8.2.2 |
| 1.14.6 | `fix: reconnect log senders` | Không: không gửi log máy ra ngoài (không có patch `logging`) |

Còn lại là phần cứng (RAID, EFI, VMware, OpenStack, NVIDIA, Apple, BGP), không liên quan.

## 3. Cách làm (Hưng chạy trên host2, giờ làm việc, cụm đã chạy ổn trên 30 phút)

Mỗi node dùng đúng schematic đang có, nếu không sẽ mất extension (bài học 06/11, `talos/schematics/longhorn.yaml`):

| Node | Schematic | Installer |
|---|---|---|
| w2, w1 | `53513e54...` (qemu-guest-agent, iscsi-tools, util-linux-tools) | `factory.talos.dev/metal-installer/53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83:v1.14.6` |
| w3 (GCP) | `37656798...` | `factory.talos.dev/gcp-installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.14.6` |
| cp1 | `ce4c9805...` (qemu-guest-agent) | `factory.talos.dev/metal-installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.14.6` |

Từ 13/11 15:30 dùng `~/bin/talos-upgrade-node.sh <ip> v1.14.6` (in kế hoạch, kiểm trước) rồi thêm `--yes` để nâng; script gom các bước dưới đây (`host2/bin/talos-upgrade-node.sh`).

Thứ tự: **w2 → w1 → w3 → cp1** (cp1 cuối, là control plane duy nhất). Mỗi node:

1. Longhorn: mọi volume `healthy`, không volume nào chỉ còn 1 replica trên node sắp nâng.
   **Trước khi nâng w1/w2:** xoá tay pod `csi-attacher` và `csi-provisioner` nếu chúng nằm trên node sắp nâng. Longhorn tự tạo PDB `minAvailable: 1` cho hai deployment này, mà từ 10/11 mỗi cái chỉ có 1 replica (`platform/longhorn/values.yaml`, để cold start nhẹ), nên drain không evict được (13/11 w2: `error when evicting ... would exceed context deadline`, node bị cordon, upgrade dừng trước khi tải installer). `kubectl delete pod` không bị PDB chặn; pod mới lên ở worker còn lại.
2. `talosctl -e 10.10.10.11 -n <ip> upgrade --image <installer> --wait`. Talos tự cordon và drain node.
3. Chờ node `Ready`, `talosctl version` ra v1.14.6, extension đủ như bảng; Longhorn rebuild xong mới sang node kế.

Riêng cp1: trước khi nâng, chụp etcd (`talosctl etcd snapshot`) và chạy bundle backup. Trong lúc cp1 khởi động lại, API mất khoảng 2–4 phút; Argo CD, kubectl dừng theo, pod đang chạy trên worker không bị ảnh hưởng.

Sau cùng: nâng `talosctl` trên host2 lên v1.14.6, sửa phiên bản trong `kien-truc.md`, ghi nhật ký.

## 4. Đường lùi

`talosctl -e 10.10.10.11 -n <ip> rollback`: Talos giữ bản cũ ở phân vùng A/B, quay về v1.14.2 và khởi động lại. etcd 3.7.3 → 3.7.1 cùng minor, đọc được dữ liệu của nhau.

## 5. Rủi ro

- HDD host2: mỗi node khởi động lại kéo theo Longhorn rebuild, đĩa nặng 10–20 phút. Làm từng node, không gộp.
- cp1: lần khởi động lại có chủ đích của control plane duy nhất. Làm lúc không có rollout, sau khi có snapshot etcd.
- w3: nâng qua KubeSpan; nếu đứt giữa chừng thì node tự quay về bản cũ (A/B), cụm vẫn chạy với w1, w2.

## 6. Kết quả 13/11

- w2: lần 1 13:51 drain lỗi (PDB CSI, xem mục 3). Lần 2 14:07–14:10. w1 14:15–14:20, sau khi Longhorn healthy. Đủ extension, tự uncordon, apiserver 0 restart.
- **demo-app sập khoảng 17 phút (14:18–14:35)** lúc nâng w1: 2 pod cùng ở w1; Kyverno admission (1 bản) cũng ở w1; policy kiểm chữ ký image failurePolicy Fail nên không tạo được pod mới; ReplicaSet chờ backoff. Trước khi nâng w3, cp1 hoặc lần sau: rải pod demo-app theo node (`topologySpreadConstraints`) và cho Kyverno admission 2 bản; tạm thời có thể kiểm `kubectl get pod -o wide` và xoá bớt một pod demo-app để nó lên node khác trước khi drain.
- 15:25, sau khi thêm PDB demo-app và Kyverno 2 bản: `kubectl drain --dry-run=server` w1, w2 và bảng PDB. demo-app và Kyverno mỗi cái 1 pod/worker, `allowed=1`: drain worker nào cũng qua. Còn chặn: `csi-attacher`, `csi-provisioner` (`allowed=0`, 1 replica, xoá tay như mục 3) và PDB instance-manager của Longhorn. PDB instance-manager chỉ được Longhorn gỡ khi node bị cordon thật, nên dry-run luôn báo chặn; drain thật w1, w2 hôm nay đã qua. w3, cp1 không có pod nào thuộc PDB.
