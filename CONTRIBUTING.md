# Contributing

이 저장소는 GitHub Flow를 기본으로 한다. 모든 변경은 `main`에서 새 브랜치를
만들고 PR로 검토한 뒤 merge한다.

## Branch Convention

브랜치는 국내 실무에서 흔히 쓰는 작업 유형 prefix와 kebab-case 설명을 조합한다.
한글 설명은 PR 제목/본문에 쓰고, 브랜치명은 도구 호환성을 위해 영문 소문자와
숫자, 하이픈만 사용한다.

```text
<type>/<short-kebab-summary>
<type>/<issue-number>-<short-kebab-summary>
```

권장 type:

| Type | Use |
|------|-----|
| `feat` | 새 기능, 새 배포 환경, 새 chart 기능 |
| `fix` | 버그 수정, 잘못된 manifest 수정 |
| `docs` | 문서만 변경 |
| `chore` | 설정, repository hygiene, 운영 보조 변경 |
| `ci` | GitHub Actions, 검증 pipeline 변경 |
| `refactor` | 동작 변경 없는 구조 개선 |
| `hotfix` | 운영 긴급 수정 |
| `release` | 릴리스 준비 |

예시:

```text
chore/bootstrap-boatlab-gitops
feat/add-prod-application
fix/boatlab-prod-ingress-host
docs/update-secret-contract
ci/add-helm-validation
```

## Commit Convention

커밋 메시지는 Conventional Commits 형식을 사용한다. 한국어 요약을 허용하되 type은
영문 소문자로 고정한다.

```text
<type>(optional-scope): <summary>
```

예시:

```text
feat(chart): add boatlab prod values
fix(ingress): correct boatlab prod host
docs: add architecture guide
ci: validate helm render output
chore: bootstrap repository defaults
```

규칙:

- 제목은 72자 안쪽으로 쓴다.
- 하나의 커밋은 하나의 의도를 가진다.
- Secret 원문, token, `.env`, Firebase service account JSON은 커밋하지 않는다.
- 배포 image tag 변경과 chart 구조 변경은 가능하면 커밋을 분리한다.
- breaking change가 있으면 본문에 `BREAKING CHANGE:`를 적는다.

## Pull Request

PR은 다음 항목을 포함해야 한다.

- 무엇을 바꿨는지
- 왜 바꿨는지
- dev/prod 영향
- Secret 또는 운영 선행 작업
- 실행한 검증 명령
- rollback 방법

PR 제목도 커밋 컨벤션과 맞춘다.

```text
feat(chart): add boatlab prod application
fix(values): correct boatlab prod host
docs: add architecture guide
```

## Validation

로컬 또는 검증 가능한 환경에서 아래 명령을 실행한다.

```bash
helm lint charts/boatlab -f charts/boatlab/values-dev.yaml
helm lint charts/boatlab -f charts/boatlab/values-prod.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml
helm template boatlab charts/boatlab -f charts/boatlab/values-prod.yaml
git diff --check
```

`helm`이 로컬에 없으면 k3s master나 CI에서 같은 명령을 실행하고 결과를 PR에 남긴다.

## Deployment Changes

Argo CD가 source of truth다. 운영 리소스를 직접 `kubectl patch`, `kubectl set image`,
`kubectl delete`로 변경했다면 반드시 후속 PR로 GitOps 상태를 맞춘다.

prod 변경은 다음 기준을 만족해야 한다.

- dev에서 같은 image tag 또는 chart 변경이 먼저 검증됨
- migration 포함 여부가 명확함
- rollback tag 또는 rollback 절차가 PR에 있음
- Secret 변경이 필요한 경우 적용 순서가 명시됨
