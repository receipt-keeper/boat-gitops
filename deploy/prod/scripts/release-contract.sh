#!/usr/bin/env bash

release_contract_error() {
    printf '오류: %s\n' "$1" >&2
    return 1
}

load_release_manifest() {
    local manifest_file="$1"
    local line
    local key
    local value
    local seen_keys=''
    local required_key

    [[ -s "$manifest_file" ]] || release_contract_error "release manifest가 없습니다: $manifest_file" || return

    unset RELEASE_VERSION GIT_TAG GIT_REVISION BACKEND_IMAGE_REPOSITORY IMAGE_TAG IMAGE_DIGEST
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *=* ]] || release_contract_error "release manifest 형식이 올바르지 않습니다." || return
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Z_]+$ ]] || release_contract_error "release manifest 키 형식이 올바르지 않습니다." || return
        [[ " $seen_keys " != *" $key "* ]] || release_contract_error "release manifest에 중복 키가 있습니다: $key" || return
        seen_keys+=" $key"

        case "$key" in
            RELEASE_VERSION) RELEASE_VERSION="$value" ;;
            GIT_TAG) GIT_TAG="$value" ;;
            GIT_REVISION) GIT_REVISION="$value" ;;
            BACKEND_IMAGE_REPOSITORY) BACKEND_IMAGE_REPOSITORY="$value" ;;
            IMAGE_TAG) IMAGE_TAG="$value" ;;
            IMAGE_DIGEST) IMAGE_DIGEST="$value" ;;
            *) release_contract_error "release manifest에 허용되지 않은 키가 있습니다: $key" || return ;;
        esac
    done < "$manifest_file"

    for required_key in RELEASE_VERSION GIT_TAG GIT_REVISION BACKEND_IMAGE_REPOSITORY IMAGE_TAG IMAGE_DIGEST; do
        [[ " $seen_keys " == *" $required_key "* ]] || release_contract_error "release manifest 필수 키가 없습니다: $required_key" || return
    done

    [[ "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || release_contract_error "RELEASE_VERSION 형식이 올바르지 않습니다." || return
    [[ "$GIT_TAG" == "v${RELEASE_VERSION}" ]] || release_contract_error "GIT_TAG는 v\${RELEASE_VERSION}과 일치해야 합니다." || return
    [[ "$GIT_REVISION" =~ ^[0-9a-f]{40}$ ]] || release_contract_error "GIT_REVISION 형식이 올바르지 않습니다." || return
    [[ "$BACKEND_IMAGE_REPOSITORY" == ghcr.io/receipt-keeper/boat-backend ]] || release_contract_error "BACKEND_IMAGE_REPOSITORY가 허용된 저장소가 아닙니다." || return
    [[ "$IMAGE_TAG" == "sha-${GIT_REVISION:0:7}" ]] || release_contract_error "IMAGE_TAG는 GIT_REVISION의 7자리 SHA 태그와 일치해야 합니다." || return
    [[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || release_contract_error "IMAGE_DIGEST 형식이 올바르지 않습니다." || return

    export RELEASE_VERSION GIT_TAG GIT_REVISION BACKEND_IMAGE_REPOSITORY IMAGE_TAG IMAGE_DIGEST
}
