# Truy cập các giao diện của cụm

Cập nhật: 29/10/2026 (thêm Jenkins, GitLab, SonarQube; tài khoản chỉ xem).

Không ghi mật khẩu hay token vào repo này. Mật khẩu tài khoản dự phòng chỉ lưu trên host2, ngoài Git.

## 1. Chuẩn bị máy (một lần)

Từ 16/10 các giao diện mở thẳng từ LAN qua HAProxy :443 trên kvm-host2 `192.168.136.38`. HAProxy chỉ nhận một số IP trong LAN; máy mới cần nhờ Hưng thêm IP vào danh sách.

1. **File hosts** (DNS công ty không phân giải `*.talos.internal`). Thêm các dòng sau (Windows: `C:\Windows\System32\drivers\etc\hosts`, mở bằng quyền admin; mỗi dòng tối đa 9 tên):

   ```text
   192.168.136.38 grafana.talos.internal headlamp.talos.internal argocd.talos.internal keycloak.talos.internal
   192.168.136.38 demo.talos.internal demo-preview.talos.internal harbor.talos.internal vault.talos.internal
   192.168.136.38 prometheus.talos.internal alertmanager.talos.internal
   192.168.136.38 jenkins.talos.internal gitlab.talos.internal sonarqube.talos.internal
   ```

2. **Tin CA nội bộ** `talos-kvm internal CA` (chứng chỉ công khai, không có khoá riêng): xin file `talos-internal-ca.crt` từ Hưng, cài vào Trusted Root Certification Authorities (Windows) hoặc Keychain (macOS). Không cài thì trình duyệt báo chứng chỉ không tin cậy.

## 2. Các giao diện

| Dịch vụ | Link | Đăng nhập | Ghi chú |
|---|---|---|---|
| Argo CD | https://argocd.talos.internal | Keycloak ("LOG IN VIA KEYCLOAK") | trạng thái đồng bộ của 18 app |
| Grafana | https://grafana.talos.internal | Keycloak; xem ẩn danh quyền Viewer | dashboard cụm, demo-app, Keycloak |
| Headlamp | https://headlamp.talos.internal | Keycloak | `talos-viewers` chỉ xem, không đọc Secret |
| Harbor | https://harbor.talos.internal | Keycloak (LOGIN VIA OIDC PROVIDER) | project `talos`, replication từ GHCR |
| Vault | https://vault.talos.internal | Keycloak (method OIDC) | `talos-viewers` chỉ đọc |
| Prometheus | https://prometheus.talos.internal | Keycloak qua oauth2-proxy | chỉ nhóm `talos-admins` |
| Alertmanager | https://alertmanager.talos.internal | Keycloak qua oauth2-proxy | chỉ nhóm `talos-admins` |
| Keycloak | https://keycloak.talos.internal | tài khoản Keycloak | realm `talos`; quản trị realm chỉ admin |
| demo-app | https://demo.talos.internal | không cần | bản đang nhận traffic |
| demo-app preview | https://demo-preview.talos.internal | không cần | bản mới trong lúc blue-green |
| Jenkins | https://jenkins.talos.internal | Keycloak (SAML) | pipeline DevSecOps của demo-app; chạy trên Google Cloud |
| GitLab CE | https://gitlab.talos.internal | Keycloak (nút SAML) | user mới chờ admin duyệt; `talos-viewers` là External, chỉ thấy project được thêm vào |
| SonarQube | https://sonarqube.talos.internal | Keycloak (SAML) | quality gate của demo-app |

Jenkins, GitLab CE, SonarQube chạy trên VM Google Cloud và chỉ nghe nội bộ trên VM; host2 giữ đường hầm SSH tới chúng (`host2/systemd/gcp-tunnel-*.service`), Traefik trong cụm cấp link `*.talos.internal`. Không mở cổng nào trên GCP ra Internet, nên 3 link này cũng chỉ vào được trong LAN công ty. VM GCP tự tắt 17:15, bật 08:15 (T2–T6): ngoài giờ đó 3 link báo lỗi 502.

**Tài khoản Keycloak**: nhờ Hưng tạo user trong realm `talos` bằng `platform/keycloak/add-user.sh <user> talos-viewers|talos-admins` (mật khẩu tạm, bắt đổi ở lần đăng nhập đầu). Tài khoản chỉ xem cho anh hướng dẫn: `mentor_view` (`talos-viewers`).

**Khi Keycloak hỏng**: mỗi công cụ còn một tài khoản dự phòng cục bộ (Argo CD, Grafana, Harbor `admin`; Headlamp token ServiceAccount). Mật khẩu ở host2, xin Hưng khi cần.

## 3. Dự phòng: SSH tunnel qua kvm-host2

Dùng khi HAProxy hoặc Traefik có vấn đề. Cần tài khoản SSH trên host2; `kvm-host2` là alias SSH trỏ tới `192.168.136.38`.

```bash
ssh -L 3000:127.0.0.1:3000 kvm-host2 "KUBECONFIG=~/talos-kvm/kubeconfig kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
```

Mở http://localhost:3000. Headlamp tương tự với `-n headlamp svc/headlamp 8080:80`, rồi lấy token chỉ xem 8 giờ thẳng vào clipboard:

```powershell
ssh kvm-host2 "KUBECONFIG=~/talos-kvm/kubeconfig kubectl -n headlamp create token headlamp-viewer --duration=8h" | Set-Clipboard
```
