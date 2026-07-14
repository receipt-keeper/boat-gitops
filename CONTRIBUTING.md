# Contributing

## 브랜치 규칙

이 저장소는 GitHub Flow를 사용한다. 모든 변경은 `main`에서 작업 브랜치를 만들고
PR 검토를 거쳐 `main`에 병합한다. backend 애플리케이션의 release 브랜치 정책과
GitOps 저장소의 배포 변경 흐름은 분리한다.

```text
<type>/<short-kebab-summary>
<type>/<issue-number>-<short-kebab-summary>
```

| Type | 용도 |
|---|---|
| `feat` | 새 기능과 배포 환경 |
| `fix` | 버그와 잘못된 설정 수정 |
| `docs` | 문서만 변경 |
| `chore` | 저장소와 운영 보조 설정 |
| `ci` | GitHub Actions와 검증 pipeline |
| `refactor` | 동작 변경 없는 구조 개선 |
| `release` | 릴리스 준비 |
| `hotfix` | 운영 긴급 수정 |

브랜치명은 영문 소문자, 숫자, 하이픈을 사용한다.

## 커밋 규칙

Conventional Commits 형식을 사용하고 요약은 한글로 작성한다.

```text
<type>(optional-scope): <한글 요약>
```

예시:

```text
feat(prod): 운영 blue green 배포 구성 추가
fix(nginx): 운영 health 라우팅 수정
docs(prod): 인증서 갱신 절차 문서화
ci: 개발 Helm 렌더 검증 추가
```

- 제목은 72자 이내로 작성한다.
- 하나의 커밋은 하나의 의도를 가진다.
- Secret, token, `.env`, Firebase JSON, private key를 커밋하지 않는다.
- image tag 변경과 배포 구조 변경은 가능하면 분리한다.
- breaking change는 본문에 `BREAKING CHANGE:`를 기록한다.

## Pull Request

PR에는 변경 이유, dev/prod 영향, Secret 선행 작업, 검증 결과, rollback 방법을 적는다.
PR 제목도 커밋 규칙을 따른다. 운영 PR은 사용자 승인 전 임의 병합하지 않는다.

## 검증

```bash
helm lint charts/boatlab -f charts/boatlab/values-dev.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml
bash -n deploy/prod/scripts/*.sh
bash deploy/prod/tests/deploy-state-machine.sh
git diff --check
```

Compose와 Nginx 검증에는 실제 Secret 대신 임시 dummy 파일을 사용한다. 상세 명령은
`.github/workflows/validate.yaml`을 기준으로 한다.

## 배포 변경

- dev는 Argo CD 자동 sync, prune, self-heal을 유지한다.
- prod는 `production` Environment 승인 후 `workflow_dispatch`로만 배포한다.
- 운영 이미지는 `deploy/prod/config/image-tag`와 `image-digest` 변경 PR로 기록한다.
- 운영 workflow 입력은 병합된 `image-tag`와 같은 `sha-*` immutable tag만 사용한다.
- 운영 DB migration은 이전 active 앱과 호환되는 forward migration이어야 한다.
- scheduler는 systemd timer가 자동 실행하며 사람이 5분마다 실행하지 않는다.
- 실패 시 기존 슬롯 유지 여부와 이전 SHA rollback 절차를 PR에 기록한다.
