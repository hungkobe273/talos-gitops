# Nhật ký thay đổi

Ghi mỗi thay đổi về hạ tầng, cấu hình cụm hoặc ứng dụng: ngày, thay đổi, lý do, commit (nếu có). Mới nhất ở trên.

Thay đổi nằm ngoài repo này (host2, cấu hình Talos) cũng ghi ở đây, vì repo không chứa file cấu hình Talos (có secret).

## 16/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Grafana: request 384Mi, limit 1Gi (trước 256Mi/512Mi) | Grafana chạm limit 512Mi, đọc lại đĩa liên tục, HDD nghẽn, API cụm gián đoạn 10:34–10:45 | `3675921` |
| Backup etcd tự động trên host2: systemd timer 16:45, giữ 7 bản, báo Telegram khi lỗi | Có bản khôi phục etcd hằng ngày | ngoài repo |
| Talos `TimeSyncConfig`: lấy giờ qua KVM PTP, `bootTimeout: 2m`; host2 NTP `time.cloudflare.com` | Sáng 16/10 host mất Internet, Talos chờ đồng bộ giờ, etcd không chạy | ngoài repo |
| Thêm tài liệu `docs/` (báo cáo, kiến trúc, truy cập, nhật ký thay đổi) | Anh hướng dẫn yêu cầu đưa tài liệu lên GitHub và cập nhật theo thay đổi | commit này |

## 15/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Thêm Headlamp (chart 0.45.0), tài khoản `headlamp-admin` và `headlamp-viewer`, tắt binding cluster-admin mặc định | Dashboard quản trị có phân quyền | `3d76a15` |
| Cảnh báo lỗi chỉ tính `GET /api/work`; Grafana chờ 5 phút trước liveness probe | Giảm cảnh báo nhầm; Grafana khởi động chậm trên HDD | `badb948` |
| Grafana: request 256Mi, limit 512Mi | Grafana limit 256Mi làm IO cao, 3 apiserver unready lúc 14:14 | `4ced58e` |
| Thêm SealedSecrets: `telegram-bot`, `grafana-admin`, `ghcr-pull` | Không để secret dạng thô trong Git | `45e31fe` |
| RAM control plane 2560 → 2048 MB; host2 `vm.swappiness=10`; etcd heartbeat 500 ms, election 5000 ms | Host thiếu RAM và swap, etcd trên HDD bầu leader liên tục | ngoài repo |

## 09/10/2026

| Thay đổi | Lý do | Commit |
|---|---|---|
| Thêm README | Mô tả repo | `46af2a3` |
| Thêm manifest demo-app, Argo CD apps, values monitoring | Khởi tạo GitOps | `56de7a0` |
