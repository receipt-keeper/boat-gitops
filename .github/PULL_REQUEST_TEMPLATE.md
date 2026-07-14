## 요약

-

## 변경 유형

- [ ] feat
- [ ] fix
- [ ] docs
- [ ] chore
- [ ] ci
- [ ] refactor
- [ ] hotfix
- [ ] release

## 대상 환경

- [ ] dev
- [ ] prod
- [ ] 공통
- [ ] 문서/CI만 변경

## 변경 내용

-

## 운영 영향

- Secret 변경 필요: 아니오
- DB migration 포함: 아니오
- downtime 예상: 아니오

## 검증

- [ ] `git diff --check`
- [ ] `helm lint charts/boatlab -f charts/boatlab/values-dev.yaml`
- [ ] `helm template boatlab charts/boatlab -f charts/boatlab/values-dev.yaml`
- [ ] `bash deploy/prod/tests/deploy-state-machine.sh`
- [ ] `docker compose -f deploy/prod/compose.yaml config`
- [ ] Nginx bootstrap/final 설정 `nginx -t`
- [ ] 운영 image 변경 시 `deploy/prod/config/image-tag`, `image-digest` 갱신

## Rollback

-

## 참고

-
