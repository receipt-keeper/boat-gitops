# boat-gitops

Boatlab backend의 개발 Kubernetes 배포와 운영 서버 배포 구성을 관리한다.

## 배포 환경

| 환경 | 배포 방식 | 주소 | 설정 |
|---|---|---|---|
| dev | Argo CD + Helm | `https://boatlab-dev.luigi99.cloud` | `charts/boatlab/values-dev.yaml` |
| prod | GitHub Actions + Docker Compose | `https://api.boatlab.co.kr` | `deploy/prod/` |

운영 Kubernetes Application은 만들지 않는다. 현재 Argo CD가 관리하는 Boatlab 환경은
`boatlab-dev`뿐이며, 운영은 별도 인스턴스에서 Nginx와 backend blue/green
컨테이너로 실행한다.

## 저장소 구조

```text
.
|-- .github/workflows/
|   |-- validate.yaml
|   `-- deploy.yml
|-- argocd/applications/boatlab-dev.yaml
|-- charts/boatlab/                     # dev Helm chart
|-- deploy/prod/
|   |-- config/                         # image tag, digest, runtime env 예시
|   |-- nginx/                          # Nginx 설정 template
|   |-- scripts/                        # bootstrap, 배포, 인증서 스크립트
|   |-- systemd/                        # scheduler, 인증서 timer
|   |-- tests/                          # 배포 상태 전환 테스트
|   `-- compose.yaml
|-- AGENTS.md
|-- ARCHITECTURE.md
|-- CONTRIBUTING.md
`-- README.md
```

## 개발 환경 검증

```bash
helm lint charts/boatlab -f charts/boatlab/values-dev.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml
```

개발 Secret은 chart가 생성하지 않는다. `boatlab-backend-app`,
`boatlab-backend-db`, `boatlab-firebase`, `ghcr-secret`을 namespace에 외부 입력으로
준비한다. migration은 Argo CD `PreSync` Job으로 `alembic upgrade head`를 실행한다.

## 운영 환경 배포

운영 배포는 GitHub `production` Environment 승인 후 `boatlab 운영 배포` workflow를
직접 실행해야 시작된다. merge와 tag 생성만으로는 배포되지 않는다.

- 입력은 `sha-*` immutable backend 이미지 태그만 허용한다.
- `deploy/prod/config/image-tag`와 `image-digest` 변경 PR을 먼저 병합하고 같은 tag를 workflow에 입력한다.
- migration, 비활성 backend health, Nginx 전환, HTTPS health 순으로 진행한다.
- scheduler는 systemd timer가 5분마다 one-shot 컨테이너를 실행한다.
- Certbot 갱신은 별도 systemd timer가 매일 확인한다.
- Secret과 Firebase 서비스 계정 JSON은 GitHub Environment에만 저장한다.
