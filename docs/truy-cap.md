# Truy cập Grafana và Headlamp

Cập nhật: 16/10/2026.

| Dịch vụ | Link | Đăng nhập | Ghi chú |
|---|---|---|---|
| Grafana | http://localhost:3000 | user `admin`, mật khẩu xin Hưng | Cần mở SSH tunnel trước (mục 1) |
| Headlamp | http://localhost:8080 | token ngắn hạn 8 giờ | Cần mở SSH tunnel trước (mục 1) |

Link trực tiếp từ LAN `192.168.136.x` chưa có, xem mục 2.

Không ghi mật khẩu hay token vào repo này. Mật khẩu Grafana chỉ lưu trên host2, ngoài Git.

## 1. Cách hiện tại: SSH tunnel qua kvm-host2

Grafana và Headlamp chạy trong cụm, ở mạng NAT `10.10.10.0/24` phía sau kvm-host2, nên máy trên LAN không mở thẳng được. Cách hiện tại: SSH vào host2, cho `kubectl port-forward` chạy trên host2, rồi chuyển cổng về máy mình bằng `ssh -L`.

Yêu cầu: có tài khoản SSH trên kvm-host2 (`192.168.136.38`) và máy đang ở LAN công ty. Trong các lệnh dưới, `kvm-host2` là alias SSH trỏ tới `192.168.136.38` (khai báo trong `~/.ssh/config`).

### Grafana

Mở một cửa sổ terminal (PowerShell trên Windows, Terminal trên macOS), chạy và để nguyên cửa sổ đó:

```bash
ssh -L 3000:127.0.0.1:3000 kvm-host2 "KUBECONFIG=~/talos-kvm/kubeconfig kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
```

Mở http://localhost:3000. Đóng cửa sổ terminal thì tunnel tắt.

### Headlamp

Cửa sổ thứ nhất, để nguyên:

```bash
ssh -L 8080:127.0.0.1:8080 kvm-host2 "KUBECONFIG=~/talos-kvm/kubeconfig kubectl -n headlamp port-forward svc/headlamp 8080:80"
```

Cửa sổ thứ hai, lấy token chỉ xem (8 giờ) thẳng vào clipboard, không in ra màn hình:

Windows (PowerShell):

```powershell
ssh kvm-host2 "KUBECONFIG=~/talos-kvm/kubeconfig kubectl -n headlamp create token headlamp-viewer --duration=8h" | Set-Clipboard
```

macOS:

```bash
ssh kvm-host2 "KUBECONFIG=~/talos-kvm/kubeconfig kubectl -n headlamp create token headlamp-viewer --duration=8h" | pbcopy
```

Mở http://localhost:8080, dán token vào ô đăng nhập.

| Tài khoản Headlamp | Quyền |
|---|---|
| `headlamp-viewer` | Chỉ xem tài nguyên cụm, không đọc Secret |
| `headlamp-admin` | cluster-admin, chỉ dùng khi cần sửa |

Người không có tài khoản trên host2: nhờ Hưng tạo token `headlamp-viewer` và gửi riêng (không gửi vào nhóm chat).

## 2. Truy cập trực tiếp từ LAN 192.168.136.x (chưa làm)

Yêu cầu của anh hướng dẫn: máy trong dải `192.168.136.x` mở được Grafana và Headlamp bằng link, không cần tài khoản SSH trên host2.

Hướng làm: kvm-host2 nhận kết nối trên IP LAN `192.168.136.38` và chuyển tiếp vào dịch vụ trong cụm. Khi xong, cập nhật bảng đầu file với link dạng `http://192.168.136.38:<cổng>`, cách đăng nhập, và ghi vào [nhat-ky-thay-doi.md](nhat-ky-thay-doi.md).

Cần chốt khi làm:

- Cách chuyển tiếp: reverse proxy hoặc chuyển cổng trên host2 tới Service trong cụm (NodePort hoặc tương đương), quản lý bằng systemd và GitOps để tự lên lại khi host bật mỗi sáng.
- Bảo mật: chỉ mở trong LAN, giới hạn IP nguồn được vào nếu có thể; Headlamp chỉ cấp token `headlamp-viewer`; chưa có TLS nên không dùng mật khẩu quan trọng.
