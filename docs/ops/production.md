# 운영 배포

## 범위

운영 API는 `https://api.boatlab.co.kr`이며 운영 인스턴스
`43.202.141.209`에서 실행한다. dev의 `boatlab-dev` Argo CD Application과 Helm
values는 변경하지 않는다. 운영 Kubernetes 리소스는 만들지 않는다.

초기 backend 이미지는
`ghcr.io/receipt-keeper/boat-backend:sha-be4791d`를 사용한다.
운영 기준 태그와 manifest digest는 `deploy/prod/image-tag`, `image-digest`에 기록한다.

## 서버 경로

```text
/opt/boatlab/prod/
  bootstrap.sh
  compose.yaml
  deploy.sh
  run-release.sh
  renew-certificate.sh
  image-digest
  nginx.conf.template
  nginx-bootstrap.conf.template
  boatlab-scheduler.service
  boatlab-scheduler.timer
  boatlab-certbot-renew.service
  boatlab-certbot-renew.timer
/etc/boatlab/prod/
  runtime.env
  release.env
  active-slot
  nginx/default.conf
  firebase/service-account.json
/etc/letsencrypt/
/var/www/boatlab-certbot/
```

`runtime.env`와 Firebase JSON은 root 소유 mode 600이다. backend blue/green에만
Firebase JSON을 read-only mount한다. migration과 scheduler는 runtime env만 사용한다.

## GitHub production Environment

required reviewer를 지정하고 다음 이름을 등록한다.

| 구분 | 이름 |
|---|---|
| Secret | `PRODUCTION_HOST` |
| Secret | `PRODUCTION_USER` |
| Secret | `PRODUCTION_SSH_PRIVATE_KEY` |
| Secret | `PRODUCTION_KNOWN_HOSTS` |
| Secret | `PRODUCTION_RUNTIME_ENV` |
| Secret | `PRODUCTION_FIREBASE_JSON` |
| Secret | `PRODUCTION_GHCR_USERNAME` |
| Secret | `PRODUCTION_GHCR_TOKEN` |
| Variable | `PRODUCTION_LETSENCRYPT_EMAIL` |

등록된 이름만 확인하고 값을 출력하지 않는다.

```bash
gh secret list --repo receipt-keeper/boat-gitops --env production
gh variable list --repo receipt-keeper/boat-gitops --env production
```

runtime env 계약은 `deploy/prod/runtime.env.example`을 따른다. instance와
S3 Object Storage는 같은 region에서 instance resource access로 연결하며, 정적
`S3_ACCESS_KEY_ID`와 `S3_SECRET_ACCESS_KEY`는 넣지 않는다. Firebase JSON은 모바일
`google-services.json`이 아니라 서버용 service account JSON을 사용한다.

## 최초 bootstrap

병합된 저장소에서 bootstrap 파일을 서버로 전달하고 두 번 실행해도 성공하는지
확인한다.

```bash
scp deploy/prod/bootstrap.sh boatlab-prod:~/boatlab-bootstrap.sh
ssh boatlab-prod 'chmod 0600 ~/boatlab-bootstrap.sh && sudo install -m 0750 ~/boatlab-bootstrap.sh /usr/local/sbin/boatlab-bootstrap && rm -f ~/boatlab-bootstrap.sh'
ssh boatlab-prod 'sudo /usr/local/sbin/boatlab-bootstrap'
ssh boatlab-prod 'sudo /usr/local/sbin/boatlab-bootstrap'
ssh boatlab-prod 'sudo docker compose version && sudo ufw status'
```

bootstrap은 Docker Engine과 Compose plugin을 설치하고 22, 80, 443 포트를 허용한 뒤
운영 디렉터리를 만든다. 인스턴스 외부 방화벽에서도 TCP 80과 443이
허용되어 있어야 한다.

## 수동 배포

먼저 `deploy/prod/image-tag`와 `image-digest`를 원하는 이미지로 변경한 PR을 병합한다.
GitHub Actions에서 `boatlab 운영 배포` workflow를 선택하고
`image_tag`에 병합된 파일과 같은 값을 입력한다. merge나 release tag만으로 workflow가
실행되지는 않는다.

배포 순서:

1. 이미지 태그, runtime env, Firebase JSON, Let's Encrypt email을 검사한다.
2. 운영 파일과 Secret을 서버에 설치한다.
3. 임시 `/run/boatlab-prod-docker-config`로 GHCR에 로그인한다.
4. 새 이미지로 `alembic upgrade head`를 실행한다.
5. inactive backend를 시작하고 container health를 확인한다.
6. 인증서가 없으면 Nginx HTTP bootstrap과 Certbot webroot로 최초 발급한다.
7. final Nginx config를 검사하고 새 슬롯으로 reload한다.
8. origin에서 `https://api.boatlab.co.kr/health`와 인증서를 확인한다.
9. active 슬롯을 기록하고 이전 backend를 종료한다.
10. GHCR credential을 삭제하고 scheduler와 인증서 갱신 timer를 활성화한다.

배포 실패 시 workflow cleanup은 GHCR credential을 삭제한다. 기존 release가 있으면
기존 scheduler와 인증서 timer를 다시 시작한다.

## TLS와 인증서 갱신

Nginx는 80에서 ACME challenge를 제공하고 나머지 요청을 HTTPS로 redirect한다.
443에서 TLS를 종료하고 active backend로 proxy한다. Certbot timer는 매일 갱신
필요 여부를 확인하고 Nginx config 검사 후 reload한다.

```bash
ssh boatlab-prod 'sudo systemctl status boatlab-certbot-renew.timer --no-pager'
ssh boatlab-prod 'sudo systemctl start boatlab-certbot-renew.service'
ssh boatlab-prod 'sudo journalctl -u boatlab-certbot-renew.service -n 100 --no-pager'
```

최초 발급 후 갱신 dry-run은 운영 트래픽이 안정된 상태에서 실행한다.

```bash
ssh boatlab-prod 'sudo /opt/boatlab/prod/renew-certificate.sh --dry-run'
```

갱신 스크립트는 `/etc/boatlab/prod/release.env`에서 현재 이미지 태그를 읽는다.

## Scheduler

systemd timer는 5분마다 아래 one-shot을 실행한다. `flock`이 중복 실행을 막고,
이전 실행이 남아 있으면 새 실행은 성공 상태로 건너뛴다.

```text
python -m app.modules.notifications.jobs.schedule_push_notifications --dry-run=false
```

scheduler는 notification, occurrence, outbox를 생성하고 실제 FCM은 API 프로세스의
outbox relay가 처리한다. scheduler에 Firebase JSON이나 별도 FCM Secret을 넣지 않는다.

```bash
ssh boatlab-prod 'sudo systemctl status boatlab-scheduler.timer --no-pager'
ssh boatlab-prod 'sudo systemctl start boatlab-scheduler.service'
ssh boatlab-prod 'sudo journalctl -u boatlab-scheduler.service -n 100 --no-pager'
```

## 운영 검증

```bash
curl --fail --show-error https://api.boatlab.co.kr/health
ssh boatlab-prod 'sudo cat /etc/boatlab/prod/active-slot'
ssh boatlab-prod 'sudo cat /etc/boatlab/prod/release.env'
ssh boatlab-prod 'sudo docker compose -f /opt/boatlab/prod/compose.yaml ps'
```

Secret 원문은 출력하지 않는다. 추가 E2E 항목은 다음과 같다.

- Alembic current가 head인지 확인
- Firebase 로그인과 JWT refresh
- OCR multipart 요청
- 정적 AWS key 없이 S3 업로드·조회·삭제
- scheduler의 notification·occurrence·outbox 생성
- API outbox relay의 FCM 처리
- 같은 SHA 재배포를 통한 blue/green 슬롯 교대
- 의도적인 잘못된 SHA 또는 health 실패 시 기존 active 슬롯 유지
- `boatlab-dev` Argo CD Synced/Healthy 유지

## Rollback

이전 정상 `sha-*`를 같은 workflow에 입력한다. health와 Nginx 검사를 통과한 경우에만
upstream이 이전 이미지 슬롯으로 전환된다. migration은 forward-only이므로 schema
downgrade는 자동 실행하지 않는다.
