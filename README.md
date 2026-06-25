# boatlab-gitops

Boatlab backend GitOps repository for Argo CD.

## Structure

```text
.
|-- argocd/applications/          # Argo CD Application manifests
`-- charts/boatlab/          # Single Helm chart for dev and prod
    |-- values-dev.yaml
    `-- values-prod.yaml
```

The chart keeps one deployment template and separates environments through Helm
values. Secrets are external inputs and are not committed to this repository.

## Environments

| Environment | Namespace | Host | Values file |
|-------------|-----------|------|-------------|
| dev | `boatlab-dev` | `boatlab-dev.luigi99.cloud` | `charts/boatlab/values-dev.yaml` |
| prod | `boatlab-prod` | `boatlab.luigi99.cloud` | `charts/boatlab/values-prod.yaml` |

## Required External Secrets

Create these secrets in each target namespace before syncing the Argo CD
Application:

- `boatlab-backend-app`: application env, including `DATABASE_URL`,
  `JWT_SECRET_KEY`, `REFRESH_TOKEN_PEPPER`, Firebase settings, OCR provider keys,
  and token TTL settings.
- `boatlab-backend-db`: PostgreSQL env, including `POSTGRES_USER`,
  `POSTGRES_PASSWORD`, and `POSTGRES_DB`.
- `boatlab-firebase`: Firebase service account JSON mounted into the backend pod.
- `ghcr-secret`: image pull secret for GHCR.

## Render Locally

```bash
helm lint charts/boatlab -f charts/boatlab/values-dev.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml

helm lint charts/boatlab -f charts/boatlab/values-prod.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-prod.yaml
```

## Argo CD Bootstrap

Apply the desired Application manifest from the cluster where Argo CD is
installed:

```bash
kubectl apply -f argocd/applications/boatlab-dev.yaml
kubectl apply -f argocd/applications/boatlab-prod.yaml
```

The migration job is rendered as an Argo CD `PreSync` hook and runs
`alembic upgrade head` with the same backend image tag as the application.
