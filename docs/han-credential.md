# Bảng hạn credential

Bảng duy nhất cho mọi credential có hạn hoặc cần xoay (audit #11, 13/11/2026). Chỉ ghi tên, chỗ dùng và hạn; **không ghi giá trị**. Đổi hạn ở đâu thì sửa bảng này trong cùng lần commit.

Cách kiểm lại cột "Hết hạn":

- PAT GitHub: GitHub, Settings, Developer settings, Personal access tokens (classic và fine-grained), cột Expires.
- Chứng chỉ: `openssl x509 -noout -enddate` (kubeconfig, talosconfig), `kubectl get certificate -A -o custom-columns=NS:.metadata.namespace,N:.metadata.name,EXP:.status.notAfter`.

## 1. Có hạn cứng (hết hạn là gãy)

| Credential | Dùng ở | Loại | Hết hạn | Gãy gì khi hết | Gia hạn |
|---|---|---|---|---|---|
| Jenkins `github-read` | Jenkins job `demo-app-gce`, checkout `talos-demo-app` | PAT fine-grained `jenkins-gce-read-demo-app`, Contents read | **31/01/2027** (regenerate 13/11) | Build không checkout được | Mục 2 |
| Jenkins `ghcr` | Jenkins push image lên GHCR | PAT classic `jenkins-gce-ghcr`, scope `repo`, `write:packages` | 31/01/2027 | Build không push image | Mục 2 |
| GitLab CI (biến GHCR) | GitLab runner push image lên GHCR | PAT classic `gitlab-gce-ghcr`, scope `repo`, `write:packages` | 31/01/2027 | Pipeline GitLab không push image | Như mục 2, cập nhật biến CI trong GitLab |
| Jenkins `sonarqube-token` | Jenkins phân tích SonarQube | Token SonarQube, 90 ngày | Hưng điền (xem trong SonarQube, My Account, Security) | Bước SonarQube lỗi | Tạo token mới trong SonarQube, cập nhật credential |
| Secret `ghcr-pull` (ns `demo`, `keycloak`, SealedSecret trong Git) | Cụm kéo image từ GHCR, Kyverno đọc chữ ký, `image-scan` | PAT classic `talos-kvm ghcr-pull (read only)`, `read:packages` | **13/01/2027** (sớm nhất trong bảng) | Pod mới không kéo được image, Kyverno từ chối pod | Tạo PAT mới, seal lại bằng `kubeseal`, commit |
| `kubeconfig` (admin) | host2, laptop | Chứng chỉ client Talos | 14/10/2027 | Mất `kubectl` | `talosctl kubeconfig` sinh lại |
| `talosconfig` (os:admin) | host2 | Chứng chỉ client Talos | 14/10/2027 | Mất `talosctl` | `talosctl config new` từ `secrets.yaml` |
| Chứng chỉ Ingress (`*-tls`, cert-manager) | Mọi dịch vụ `*.talos.internal` | Ký bởi `talos-internal-ca` | 14/01–27/01/2027 | Không, cert-manager tự gia hạn trước hạn | Tự động; kiểm cột EXP thỉnh thoảng |
| `talos-internal-ca` | CA nội bộ | CA tự ký | 13/10/2036 | – | – |
| GCP free trial | w3, Jenkins, GitLab, GCS, KMS | Tài khoản | 22/01/2027 | Mọi thứ trên GCP dừng | Quyết định trước 01/2027 (xem `de-xuat-giam-chi-phi-gcp.md`) |

Ghi chú 13/11: hai PAT push (`jenkins-gce-ghcr`, `gitlab-gce-ghcr`) có scope `repo`, tức đọc ghi được mọi repo của tài khoản, kể cả `talos-gitops` mà Argo CD tự sync. Push GHCR chỉ cần `write:packages`. Lần gia hạn tới nên tạo token mới chỉ `write:packages` thay vì Regenerate.

## 2. Gia hạn PAT Jenkins (Hưng làm, trên web)

1. GitHub, Settings, Developer settings, Fine-grained tokens: mở token của `github-read`, bấm **Regenerate** (giữ nguyên quyền: repo `talos-demo-app`, Contents read-only). Chọn hạn 90 ngày để bớt số lần gia hạn.
2. Jenkins, Manage Jenkins, Credentials, `github-read`, Update: dán token mới vào ô Password, sửa Description thành `GitHub read talos-demo-app (fine-grained, exp <ngày>)`. Save.
3. Làm tương tự với `ghcr` nếu cũng sắp hết hạn (Tokens (classic), Regenerate).
4. Không dán token vào chat, không chụp màn hình trang vừa tạo token. Xong thì xoá clipboard: `Set-Clipboard ' '`.
5. Kiểm: chạy lại job `demo-app-gce` (Build Now), bước checkout và push qua.
6. Sửa cột "Hết hạn" ở bảng trên.

## 3. Không có hạn nhưng cần xoay khi lộ hoặc định kỳ

| Credential | Dùng ở | Ghi chú |
|---|---|---|
| Khoá SA GCP `talos-backup-writer` | host2 đẩy bundle lên GCS | Chỉ objectCreator trên bucket. Đề xuất xoay 90 ngày (audit S3) |
| Khoá SA GCP `talos-velero` | Velero trong cụm (SealedSecret) | Đề xuất xoay 90 ngày |
| Khoá B2 | host2 đẩy bundle lên B2 | Khoá "write" của B2 vẫn xoá được file; muốn chống xoá cần Object Lock |
| Token bot Telegram | Cảnh báo backup, watchdog, Alertmanager | Xoay khi lộ (BotFather, revoke) |
| `vault-snapshot-token` | host2 snapshot Vault | Chu kỳ 720 giờ, tự gia hạn mỗi lần chạy; cụm tắt quá 30 ngày thì hết |
| Khoá Sealed Secrets | Controller trong cụm | Tự tạo khoá mới 30 ngày một lần, bundle xuất mọi khoá mỗi ngày |
| Khoá GPG offsite | Mã hoá bundle | Không hạn; cần bản thứ hai (`khoi-phuc-tham-hoa.md` mục 1.2) |
| Deploy key `argocd-deploy-key` | Argo CD đọc repo | Repo public, có thể bỏ hẳn |
| Mật khẩu `*-password.txt` | Tài khoản dự phòng Argo CD, Grafana, Keycloak, GitLab | Đổi khi có người rời dự án |
