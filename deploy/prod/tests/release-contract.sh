#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
source "$SCRIPT_DIR/../scripts/release-contract.sh"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

write_manifest() {
    local target="$1"
    local version="${2:-1.0.1}"
    local tag="${3:-v1.0.1}"
    local revision="${4:-a802989a5bd821006ce05b316e859738f1621910}"
    local image_tag="${5:-sha-a802989}"
    local digest="${6:-sha256:ff1e923c2b7c8b7e4debd2a69a0cf94f6c7d07c5a790f298161f68d9689c3ab3}"

    printf '%s\n' \
        "RELEASE_VERSION=$version" \
        "GIT_TAG=$tag" \
        "GIT_REVISION=$revision" \
        'BACKEND_IMAGE_REPOSITORY=ghcr.io/receipt-keeper/boat-backend' \
        "IMAGE_TAG=$image_tag" \
        "IMAGE_DIGEST=$digest" > "$target"
}

valid="$root/valid.env"
write_manifest "$valid"
load_release_manifest "$valid"
[[ "$RELEASE_VERSION" == 1.0.1 ]]
[[ "$GIT_TAG" == v1.0.1 ]]
[[ "$IMAGE_TAG" == sha-a802989 ]]

assert_invalid() {
    local manifest_file="$1"
    if load_release_manifest "$manifest_file" >/dev/null 2>&1; then
        printf '실패해야 하는 manifest가 통과했습니다: %s\n' "$manifest_file" >&2
        exit 1
    fi
}

missing="$root/missing.env"
grep -v '^IMAGE_DIGEST=' "$valid" > "$missing"
assert_invalid "$missing"

invalid_version="$root/invalid-version.env"
write_manifest "$invalid_version" 1.0 v1.0
assert_invalid "$invalid_version"

leading_zero_version="$root/leading-zero-version.env"
write_manifest "$leading_zero_version" 01.0.1 v01.0.1
assert_invalid "$leading_zero_version"

invalid_tag="$root/invalid-tag.env"
write_manifest "$invalid_tag" 1.0.1 v1.0.2
assert_invalid "$invalid_tag"

invalid_revision="$root/invalid-revision.env"
write_manifest "$invalid_revision" 1.0.1 v1.0.1 a802989 sha-a802989
assert_invalid "$invalid_revision"

invalid_image_tag="$root/invalid-image-tag.env"
write_manifest "$invalid_image_tag" 1.0.1 v1.0.1 a802989a5bd821006ce05b316e859738f1621910 sha-deadbee
assert_invalid "$invalid_image_tag"

invalid_digest="$root/invalid-digest.env"
write_manifest "$invalid_digest" 1.0.1 v1.0.1 a802989a5bd821006ce05b316e859738f1621910 sha-a802989 sha256:abc
assert_invalid "$invalid_digest"

unknown_key="$root/unknown-key.env"
cp "$valid" "$unknown_key"
printf 'UNEXPECTED=true\n' >> "$unknown_key"
assert_invalid "$unknown_key"

duplicate_key="$root/duplicate-key.env"
cp "$valid" "$duplicate_key"
printf 'RELEASE_VERSION=1.0.1\n' >> "$duplicate_key"
assert_invalid "$duplicate_key"

printf 'release contract: OK\n'
