# Kế hoạch dùng GCP: worker w3 (KubeSpan), backup, diễn tập khôi phục, staging GKE

Duyệt: anh hướng dẫn 30/10/2026 ("được, có cloud thì các bạn cứ tận dụng nhé"). Thi công dự kiến thứ Ba 03/11.

## Vì sao

Cụm gần hết RAM: request trên worker 85–97% (30/10), host2 còn khoảng 1,8 GB, cp1 có lúc chỉ còn 540 MB. Rà theo p95 7 ngày cho thấy request đã sát mức dùng thật, chỉ hạ thêm được khoảng 150Mi. Credit GCP còn khoảng 7,5 triệu đ (hạn 22/01/2027), mức tiêu hiện tại khoảng 3 triệu đến hết hạn.

## Thiết kế

- **w3**: VM GCP e2-standard-2 (2 vCPU, 8 GB), đĩa 50 GB, Talos v1.14.2, asia-southeast1-b, bật theo lịch 08:15–17:15 T2–T6 như Jenkins/GitLab. Chi phí khoảng 1,2 triệu đ đến hết hạn credit.
- **KubeSpan** (WireGuard có sẵn trong Talos) nối w3 với cp1/w1/w2 qua Internet. Firewall GCP chỉ mở UDP 51820 và TCP 50000 cho IP công cộng của công ty. Không mở 6443 hay HAProxy ra Internet.
- w3 có taint `cloud=gcp:NoSchedule`; chỉ pod có toleration mới lên.
- **Chạy trên w3**: Prometheus 752Mi, Alertmanager 112Mi, VictoriaLogs 96Mi và job lúc deploy (ZAP 320Mi, smoke test). Khoảng 2,7 GB kể cả DaemonSet, phần hệ thống và dự phòng; còn chỗ cho việc khác.
- **Giữ ở host2**: Keycloak, Vault, Harbor, Argo CD, Traefik, Kyverno, demo-app (cả bản preview), **Grafana**. Mất Internet thì chỉ mất Prometheus/Alertmanager/log; app, đăng nhập và deploy vẫn chạy.
- **Grafana và bản preview không lên w3 được**: `keycloak.talos.internal` và `harbor.talos.internal` trỏ `192.168.136.38` (IP LAN của host2, StaticHostConfig). KubeSpan chỉ nối IP của node, w3 không tới được IP này: Grafana không đăng nhập OIDC được, pod preview không kéo được image từ Harbor.
- Dự kiến sau khi chuyển: w1 khoảng 78%, w2 khoảng 80% request (w2 có thêm 320Mi trống lúc deploy vì ZAP chạy trên w3).

## Trả lời 5 câu hỏi (tra cứu và dry-run 30/10 chiều)

1. **Bật KubeSpan trên node đang chạy**: Talos 1.14 dùng tài liệu riêng `KubeSpanConfig` (không phải `machine.network.kubespan`). Discovery đã bật sẵn (`DiscoveryServiceConfig`, `discovery.talos.dev`, member của 3 node đang có). `talosctl patch mc --mode=no-reboot --dry-run` với tài liệu dưới đây đạt trên w1 và cp1, không đòi reboot:

   ```yaml
   apiVersion: v1alpha1
   kind: KubeSpanConfig
   enabled: true
   mtu: 1380
   ```

   MTU 1380 = MTU mạng GCP 1460 trừ 80 (khuyến nghị của Talos). Lúc bật, traffic giữa các node on-prem cũng đi qua WireGuard.
2. **w3 gọi API server**: VIP `10.10.10.100` đang nằm trong danh sách địa chỉ member của cp1 (`talosctl get members`), nên KubeSpan quảng bá và định tuyến được tới cp1. Giữ endpoint `https://10.10.10.100:6443`; nếu w3 không join được thì đổi endpoint của riêng w3 sang `https://10.10.10.11:6443` (cụm chỉ có 1 control plane). Không mở 6443 ra Internet.
3. **Mạng pod**: giữ `advertiseKubernetesNetworks: false` (mặc định). Flannel đóng gói VXLAN giữa IP node; IP nội bộ của w3 (subnet GCP `10.148.0.0/20`, không trùng `10.10.10.0/24`, pod `10.244.0.0/16`, service `10.96.0.0/12`) được KubeSpan quảng bá. Flannel trên w1/w2 dùng MTU 1450 lớn hơn đường KubeSpan 1380, gói lớn sẽ bị phân mảnh: thử bằng `ping -M do -s 1300/1400` giữa pod w3 và pod w1; chấp nhận được cho traffic quan sát.
4. **Đưa machine config vào w3**: không dùng metadata `user-data` (ai xem được project là đọc được secret). Boot image Talos GCP vào maintenance mode, firewall chỉ mở TCP 50000 và UDP 51820 cho IP công cộng công ty `118.70.124.66/32` (kiểm lại hôm thi công, IP có thể đổi), rồi `talosctl apply-config --insecure -n <IP công cộng w3> --file w3.yaml`. Cấm `--dry-run` cùng `--insecure`. Sau khi join thì đóng 50000 hoặc chỉ để cho IP công ty.
5. **PV trên w3**: thêm `UserVolumeConfig` `local-path-provisioner` (kiểu directory) như w1/w2, StorageClass `local-path-retain` dùng lại. Đĩa VM 50 GB pd-balanced.

Ghi chú bảo mật: 30/10 một lệnh đọc `talosctl get kubespanconfig` đã in `sharedSecret` KubeSpan ra log phiên làm việc trên laptop (không lên chat hay Git). Rủi ro thấp; cân nhắc tạo khoá mới khi bật.

**w3.yaml**: lấy từ `w1.yaml` (cùng secret cụm), sửa: đĩa cài `/dev/sda` (GCP), bỏ StaticHostConfig không cần, `machine.nodeLabels` (`topology.kubernetes.io/zone: gcp-asia-southeast1-b`), `machine.nodeTaints` (`cloud: gcp:NoSchedule`), thêm `KubeSpanConfig`. File này chứa secret: chỉ để trên host2 `~/talos-kvm/`, không commit.

## Thi công (T3 03/11)

| Giai đoạn | Việc | Lùi lại |
|---|---|---|
| 0 | Backup etcd + bundle, tạm dừng watchdog | — |
| 1 | Bật KubeSpan lần lượt cp1, w1, w2; đồng bộ cp1/w1/w2.yaml | patch tắt KubeSpan / file `.bak` |
| 2 | Tạo VM w3 từ image Talos GCP chính thức, firewall, lịch bật/tắt | xoá VM, firewall |
| 3 | Áp machine config, w3 Ready, thử pod w3 ↔ pod w1/w2 | `kubectl delete node` |
| 4 | Chuyển lần lượt VictoriaLogs → Alertmanager → Prometheus (toleration + nodeAffinity w3, PV mới: mất số đo/log cũ). Grafana ở lại w2 | revert từng commit |
| 5 | Chuyển ZAP và smoke test; thử 1 lần deploy demo-app | revert, bản cũ vẫn phục vụ |
| 6 | Kiểm tra request từng node, Grafana và log qua `mentor_view`, cảnh báo Telegram; nhật ký | — |

Mỗi lần một thay đổi, chờ PSI io < 10% rồi mới làm tiếp.

## Cuối kỳ thực tập

Trước 22/01/2027: chuyển tầng quan sát về host2 hoặc gỡ, xoá w3 và firewall.

## Các việc dùng GCP khác (anh: "dùng được gì cứ dùng", 30/10)

Credit còn khoảng 7,54 triệu đ (hạn 22/01/2027). gitlab-1 + jenkins-1 tiêu khoảng 3 triệu đến hết hạn. Tài khoản đang Free Trial: hết credit hoặc hết hạn thì tài nguyên dừng, không trừ thẻ. **Không bấm Upgrade / Activate full account.** Cuối kỳ thực tập xoá hết tài nguyên.

| # | Việc | Chi phí ước tính | Lịch |
|---|---|---|---|
| 1 | w3 e2-standard-2 (8 GB), bật theo giờ làm (mục trên) | khoảng 1,2 triệu | T3 03/11 |
| 2 | Backup lên Cloud Storage: bundle GPG hằng ngày (bản thứ hai ngoài B2), bucket asia-southeast1, giữ 30 ngày | dưới 50 nghìn | 30/10 |
| 3 | Velero (backup object Kubernetes vào GCS) + diễn tập khôi phục toàn cụm lên 3 VM Talos tạm trên GCP, đo RTO, xoá sau khi xong | khoảng 100 nghìn | T5 06/11 |
| 4 | Staging GKE (zonal, 1 node e2-medium, bật theo giờ làm): Argo CD deploy demo-app sang 2 cụm | khoảng 0,7 triệu | tuần 09/11 |
| 5 | Budget alert 50/80/95% (tính chi phí trước khi trừ credit), gửi mail admin billing | 0 | 30/10 |

Tổng thêm khoảng 2,05 triệu; cộng 3 triệu đang tiêu là khoảng 5 triệu trên 7,54 triệu.
