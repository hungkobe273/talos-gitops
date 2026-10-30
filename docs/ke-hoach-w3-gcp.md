# Kế hoạch: worker w3 trên GCP (KubeSpan)

Duyệt: anh hướng dẫn 30/10/2026 ("được, có cloud thì các bạn cứ tận dụng nhé"). Thi công dự kiến thứ Ba 03/11.

## Vì sao

Cụm gần hết RAM: request trên worker 85–97% (30/10), host2 còn khoảng 1,8 GB, cp1 có lúc chỉ còn 540 MB. Rà theo p95 7 ngày cho thấy request đã sát mức dùng thật, chỉ hạ thêm được khoảng 150Mi. Credit GCP còn khoảng 7,5 triệu đ (hạn 22/01/2027), mức tiêu hiện tại khoảng 3 triệu đến hết hạn.

## Thiết kế

- **w3**: VM GCP e2-standard-2 (2 vCPU, 8 GB), đĩa 50 GB, Talos v1.14.2, asia-southeast1-b, bật theo lịch 08:15–17:15 T2–T6 như Jenkins/GitLab. Chi phí khoảng 1,2 triệu đ đến hết hạn credit.
- **KubeSpan** (WireGuard có sẵn trong Talos) nối w3 với cp1/w1/w2 qua Internet. Firewall GCP chỉ mở UDP 51820 và TCP 50000 cho IP công cộng của công ty. Không mở 6443 hay HAProxy ra Internet.
- w3 có taint `cloud=gcp:NoSchedule`; chỉ pod có toleration mới lên.
- **Chạy trên w3**: tầng quan sát (Prometheus 752Mi, Grafana 896Mi, Alertmanager 112Mi, VictoriaLogs 96Mi) và job lúc deploy (ZAP 320Mi, smoke test). Tổng khoảng 3,6 GB kể cả DaemonSet, phần hệ thống và dự phòng.
- **Giữ ở host2**: Keycloak, Vault, Harbor, Argo CD, Traefik, Kyverno, demo-app. Mất Internet thì chỉ mất phần quan sát; app, đăng nhập và deploy vẫn chạy.
- Dự kiến sau khi chuyển: w1 khoảng 78%, w2 khoảng 57% request.

## Câu hỏi cần trả lời trước khi làm (T2 02/11, chỉ đọc tài liệu)

1. Bật KubeSpan trên node đang chạy: `talosctl patch --mode=no-reboot` được không; discovery service cần Internet.
2. w3 gọi API server bằng gì: VIP 10.10.10.100 chỉ có trong L2 của host2; có thể trỏ thẳng 10.10.10.11:6443.
3. Mạng pod qua KubeSpan: `advertiseKubernetesNetworks`, `kubelet.nodeIP.validSubnets`.
4. Đưa machine config (có secret) vào w3: không dùng metadata user-data; boot maintenance mode rồi `apply-config` qua 50000 chỉ mở cho IP công ty.
5. PV trên w3: UserVolumeConfig local-path như w1/w2.

## Thi công (T3 03/11)

| Giai đoạn | Việc | Lùi lại |
|---|---|---|
| 0 | Backup etcd + bundle, tạm dừng watchdog | — |
| 1 | Bật KubeSpan lần lượt cp1, w1, w2; đồng bộ cp1/w1/w2.yaml | patch tắt KubeSpan / file `.bak` |
| 2 | Tạo VM w3 từ image Talos GCP chính thức, firewall, lịch bật/tắt | xoá VM, firewall |
| 3 | Áp machine config, w3 Ready, thử pod w3 ↔ pod w1/w2 | `kubectl delete node` |
| 4 | Chuyển lần lượt VictoriaLogs → Alertmanager → Prometheus → Grafana (toleration + nodeAffinity w3, PV mới: mất số đo cũ, user Grafana đăng nhập lại) | revert từng commit |
| 5 | Chuyển ZAP và smoke test; thử 1 lần deploy demo-app | revert, bản cũ vẫn phục vụ |
| 6 | Kiểm tra request từng node, Grafana và log qua `mentor_view`, cảnh báo Telegram; nhật ký | — |

Mỗi lần một thay đổi, chờ PSI io < 10% rồi mới làm tiếp.

## Cuối kỳ thực tập

Trước 22/01/2027: chuyển tầng quan sát về host2 hoặc gỡ, xoá w3 và firewall.
