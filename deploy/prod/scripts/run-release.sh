#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_ROOT="/opt/boatlab/prod"

source "$DEPLOY_ROOT/scripts/release-contract.sh"

[[ "$(id -u)" -eq 0 ]] || {
    printf '오류: run-release.sh는 root 권한으로 실행해야 합니다.\n' >&2
    exit 1
}
[[ "${LETSENCRYPT_EMAIL:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || exit 2

requested_version="${RELEASE_VERSION:-}"
[[ "$requested_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 2
load_release_manifest "$DEPLOY_ROOT/config/release.env"
[[ "$requested_version" == "$RELEASE_VERSION" ]] || {
    printf '오류: 요청 버전과 release manifest가 일치하지 않습니다.\n' >&2
    exit 1
}

version_digest="$(docker buildx imagetools inspect \
    "$BACKEND_IMAGE_REPOSITORY:$RELEASE_VERSION" --format '{{.Manifest.Digest}}')"
sha_digest="$(docker buildx imagetools inspect \
    "$BACKEND_IMAGE_REPOSITORY:$IMAGE_TAG" --format '{{.Manifest.Digest}}')"
[[ "$version_digest" == "$IMAGE_DIGEST" && "$sha_digest" == "$IMAGE_DIGEST" ]] || {
    printf '오류: GHCR release tag와 저장소 digest가 일치하지 않습니다.\n' >&2
    exit 1
}

systemctl stop boatlab-scheduler.timer >/dev/null 2>&1 || true
systemctl stop boatlab-scheduler.service >/dev/null 2>&1 || true
systemctl stop boatlab-certbot-renew.timer >/dev/null 2>&1 || true
systemctl stop boatlab-certbot-renew.service >/dev/null 2>&1 || true

LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL" "$DEPLOY_ROOT/scripts/deploy.sh" deploy "$RELEASE_VERSION"

systemctl enable --now boatlab-scheduler.timer boatlab-certbot-renew.timer
systemctl is-active --quiet boatlab-scheduler.timer
systemctl is-active --quiet boatlab-certbot-renew.timer
