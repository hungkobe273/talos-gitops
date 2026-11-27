# Kế hoạch nâng Talos v1.14.6 -> v1.14.7

Soạn 27/11/2026. Chưa chạy.

## 1. Vì sao

- Talos v1.14.7 phát hành 24/11, kèm flannel v0.28.11. Bản này bỏ được mục CVE-2026-111497 (brotli-libs trong image flannel), đang bỏ qua tới 15/12 trong `platform/image-scan/image-scan.yaml`.
- Kubernetes giữ v1.37.2.

## 2. Điều kiện bắt đầu

- w3 Ready ổn định ít nhất một buổi (KubeSpan cả 3 node on-prem `up` tới w3). Thiếu w3 thì w1/w2 98 % RAM request, drain một worker sẽ để pod Pending.
- Backup đủ (etcd, Keycloak, Vault, offsite) trong ngày.
- Đầu khung CHANGE (08:30), có người theo dõi Telegram.

## 3. Các bước

1. Đọc release notes v1.14.7 (thay đổi so với v1.14.6, mục known issues).
2. Kiểm trước, không đổi gì: `host2/bin/talos-upgrade-node.sh <ip> v1.14.7` cho từng node.
3. Nâng lần lượt, mỗi node chờ script thoát 0 rồi mới sang node sau:
   1. w3 (10.148.0.4, gcp-installer);
   2. w2 (10.10.10.22), rồi w1 (10.10.10.21);
   3. cp1 (10.10.10.11) cuối cùng: script chụp etcd snapshot trước.
   Lệnh: `host2/bin/talos-upgrade-node.sh <ip> v1.14.7 --yes`.
4. Sau mỗi worker: `rollout restart` các pod ưu tiên w3 đã dồn về w1/w2.
5. Flannel chỉ đổi qua `upgrade-k8s`:
   - `talosctl -e 10.10.10.11 -n 10.10.10.11 upgrade-k8s --to 1.37.2 --dry-run`;
   - chạy thật khi dry-run chỉ báo đổi image flannel (và coredns nếu có).
6. Kiểm: `kubectl -n kube-system get ds kube-flannel -o jsonpath='{..image}'` ra `v0.28.11`; quét tay image-scan; xoá mục CVE-2026-111497 khỏi `trivyignore.yaml`.

## 4. Lùi

- Talos: `talosctl rollback` trên node vừa nâng (quay về bản cài trước).
- Flannel: `upgrade-k8s` lại với manifest cũ không có sẵn; nếu flannel mới lỗi thì giữ node cordon và báo trước khi làm tiếp.

## 5. Lịch dự kiến

- Sáng T4 02/12 (làm cả buổi) nếu w3 ổn định từ T2 30/11. Nếu chưa, lùi, hạn cứng là trước 15/12.
