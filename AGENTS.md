# AGENTS.md

Language: Korean
- 응답, 문서, 커밋 메시지, PR 제목과 본문은 한글로 작성한다.

## Project

`receipt-keeper/boat-gitops`는 Boatlab backend의 배포 구성을 관리한다.

- dev: `charts/boatlab/values-dev.yaml`을 Argo CD로 배포한다.
- prod: `deploy/prod/`를 GitHub Actions 수동 workflow로 운영 서버에 배포한다.
- `boatlab-prod` Kubernetes 리소스는 만들지 않는다.

## Rules

- Kubernetes 리소스는 Helm template로 작성하고 dev Argo CD가 소유한다.
- 운영 Nginx와 backend는 Docker 컨테이너로 실행한다.
- 운영 이미지는 `sha-*` tag와 검증된 manifest digest를 함께 기록한다.
- 운영 배포는 GitHub `production` Environment 승인과 `workflow_dispatch`로만 실행한다.
- Secret 원문, `.env`, Firebase 서비스 계정 JSON, SSH key, GHCR token은 커밋하지 않는다.
- 개발 Kubernetes Secret과 운영 GitHub Environment Secret은 외부 입력으로 본다.
- dev migration은 Argo CD `PreSync` Job, prod migration은 Compose one-shot으로 실행한다.
- prod scheduler command는 아래 값을 유지하고 runtime 이미지에 없는 `uv run`을 쓰지 않는다.

```text
python -m app.modules.notifications.jobs.schedule_push_notifications --dry-run=false
```

- scheduler는 notification, occurrence, outbox를 생성하며 실제 FCM 발송은 API
  프로세스의 outbox relay가 담당한다.
- 리소스 이름은 `boatlab` prefix를 사용한다.
- StatefulSet selector와 `volumeClaimTemplates.metadata.name=data`는 기존 PVC 계약이므로
  관련 작업이 아니면 변경하지 않는다.
- 브랜치는 작업 유형 prefix와 영문 kebab-case를 사용한다.
- 커밋과 PR 제목은 Conventional Commits 형식을 사용하고 요약은 한글로 쓴다.

## Validation

```bash
helm lint charts/boatlab -f charts/boatlab/values-dev.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml
bash -n deploy/prod/scripts/*.sh
docker compose -f deploy/prod/compose.yaml config
git diff --check
```
