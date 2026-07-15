#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROD_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PROD_ROOT
readonly RELEASE_MANIFEST_FILE="${RELEASE_MANIFEST_FILE:-${PROD_ROOT}/config/release.env}"
readonly BACKEND_REPOSITORY_URL="https://github.com/receipt-keeper/boat-backend.git"

source "$SCRIPT_DIR/release-contract.sh"

usage() {
    printf '사용법: validate-release.sh [--remote]\n'
}

resolve_digest() {
    docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'
}

validate_remote_release() {
    local tag_revision
    local version_digest
    local sha_digest

    command -v git >/dev/null 2>&1 || release_contract_error "Git 실행 파일이 필요합니다."
    command -v docker >/dev/null 2>&1 || release_contract_error "Docker 실행 파일이 필요합니다."

    tag_revision="$(git ls-remote "$BACKEND_REPOSITORY_URL" "refs/tags/${GIT_TAG}^{}" | awk 'NR == 1 { print $1 }')"
    [[ "$tag_revision" == "$GIT_REVISION" ]] || release_contract_error "Git tag가 GIT_REVISION을 가리키지 않습니다."

    version_digest="$(resolve_digest "${BACKEND_IMAGE_REPOSITORY}:${RELEASE_VERSION}")"
    sha_digest="$(resolve_digest "${BACKEND_IMAGE_REPOSITORY}:${IMAGE_TAG}")"
    [[ "$version_digest" == "$IMAGE_DIGEST" ]] || release_contract_error "버전 이미지 태그와 IMAGE_DIGEST가 일치하지 않습니다."
    [[ "$sha_digest" == "$IMAGE_DIGEST" ]] || release_contract_error "SHA 이미지 태그와 IMAGE_DIGEST가 일치하지 않습니다."
}

mode="${1:-local}"
case "$mode" in
    local) ;;
    --remote) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

load_release_manifest "$RELEASE_MANIFEST_FILE"
if [[ "$mode" == --remote ]]; then
    validate_remote_release
fi

printf 'release manifest 검증 완료: %s (%s)\n' "$RELEASE_VERSION" "$IMAGE_TAG"
