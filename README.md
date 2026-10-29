# talos-gitops

Repo GitOps của cụm talos-kvm (Talos Linux, 1 control plane + 2 worker trên kvm-host2). Argo CD đọc repo này và đưa cụm về đúng trạng thái khai báo ở đây; không `kubectl apply` tay cho ứng dụng.

## Tài liệu

| File | Nội dung |
|---|---|
| [docs/bao-cao.md](docs/bao-cao.md) | Báo cáo hiện trạng: tóm tắt, bảo mật, vận hành, sự cố, giới hạn, việc tiếp theo |
| [docs/kien-truc.md](docs/kien-truc.md) | Sơ đồ tổng thể, hạ tầng, luồng đưa code lên production, bảng thành phần và phiên bản |
| [docs/truy-cap.md](docs/truy-cap.md) | Link và cách đăng nhập các giao diện (Argo CD, Grafana, Headlamp, Harbor, Vault, ...) |
| [docs/nhat-ky-thay-doi.md](docs/nhat-ky-thay-doi.md) | Nhật ký thay đổi theo ngày, kể cả thay đổi ngoài repo |

Quy ước: thay đổi nào làm khác kiến trúc, phiên bản hoặc cách truy cập thì sửa file tương ứng trong `docs/` ngay trong cùng commit, và thêm một dòng vào `docs/nhat-ky-thay-doi.md`.

## Cấu trúc repo

```text
talos-gitops/
├── bootstrap/        # apply tay một lần: root.yaml (app-of-apps), values Argo CD, secret OIDC của Argo CD
├── argocd-apps/      # 17 Application do root quản lý (mỗi file một app)
├── platform/         # values Helm, manifest và SealedSecret của từng thành phần nền tảng
│   ├── traefik, cert-manager, local-path, descheduler, argo-rollouts
│   ├── monitoring, headlamp, oauth2-proxy
│   ├── keycloak, keycloak-db
│   ├── vault, external-secrets, kyverno, cosign (khoá công khai ký image)
│   └── harbor        # kèm script make-secrets.sh, setup-replication.sh, oidc.sh, make-pull-secret.sh
├── apps/demo-app/    # Rollout blue-green, AnalysisTemplate (smoke, tỉ lệ lỗi, ZAP), ExternalSecret
└── docs/
```

## Thứ tự đồng bộ (sync wave)

| Wave | App |
|---|---|
| -2 | sealed-secrets, cert-manager |
| -1 | cert-manager-issuers, local-path, monitoring |
| 0 | traefik, argo-rollouts, descheduler |
| 1 | vault, external-secrets, kyverno, headlamp, demo-app |
| 2 | harbor, keycloak-db |
| 3 | keycloak |
| 4 | oauth2-proxy |

Sealed Secrets và cert-manager lên trước để các app sau giải mã được secret và có chứng chỉ. demo-app đứng sau Vault/External Secrets (lấy `.env`) và Kyverno (kiểm chữ ký image).

## Ai sửa repo này

- **Jenkins** (deploy key có quyền ghi): chỉ sửa `newTag` trong `apps/demo-app/kustomization.yaml` sau khi image qua đủ các cổng và đã ký.
- **Người vận hành**: mọi thay đổi khác, qua commit. Lùi bằng `git revert <hash cụ thể>`.
- **Argo CD** (deploy key chỉ đọc): đọc repo, `selfHeal` đưa cụm về đúng repo nếu có ai sửa tay.

## Dựng lại từ đầu

1. Cài Argo CD: `helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.1 -n argocd --create-namespace -f bootstrap/argocd-values.yaml`
2. `kubectl apply -f bootstrap/argocd-oidc-keycloak-sealed.yaml -f bootstrap/root.yaml`
3. Khoá giải mã Sealed Secrets phải được khôi phục từ backup trước khi các SealedSecret trong repo dùng được. Vault cần khoá init và quyền KMS; Harbor, Keycloak cần dữ liệu DB từ backup. Chi tiết trong runbook (ngoài repo).
