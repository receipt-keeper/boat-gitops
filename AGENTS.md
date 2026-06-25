# AGENTS.md

Language: Korean
- 응답 및 문서 작성은 한글로 한다.

## Project

`receipt-keeper/boat-gitops`는 Boatlab backend를 Argo CD로 배포하기 위한 GitOps
저장소다. 하나의 Helm chart를 사용하고, `values-dev.yaml`과
`values-prod.yaml`로 환경을 구분한다.

## Layout

```text
argocd/applications/          # Argo CD Application manifests
charts/boatlab/          # Boatlab backend Helm chart
```

## Rules

- Kubernetes 리소스는 Helm template로 작성한다.
- dev/prod 차이는 template 분기가 아니라 values 파일로 표현한다.
- Secret 원문, `.env`, Firebase service account JSON, GHCR token은 커밋하지 않는다.
- `boatlab-backend-app`, `boatlab-backend-db`, `boatlab-firebase`, `ghcr-secret`은 외부에서
  미리 주입되는 입력으로 본다.
- DB migration은 앱 컨테이너 시작 명령에 넣지 말고 Argo CD `PreSync` Job hook으로
  관리한다.
- 리소스 이름은 `boatlab-backend`, `boatlab-postgresql`,
  `boatlab-backend-migrate`처럼 `boatlab` prefix를 사용한다.
- StatefulSet selector와 PVC template 이름은 신중하게 다룬다. 특히
  `volumeClaimTemplates.metadata.name=data`를 바꾸면 기존
  `data-boatlab-postgresql-0` PVC와 달라진다.

## Validation

변경 후 최소 검증:

```bash
helm lint charts/boatlab -f charts/boatlab/values-dev.yaml
helm lint charts/boatlab -f charts/boatlab/values-prod.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-prod.yaml
```
