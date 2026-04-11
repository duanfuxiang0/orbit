#!/usr/bin/env bash
set -euo pipefail

# Build release artifacts for GitHub Releases.
# Usage:
#   scripts/release.sh v0.1.0
#
# Optional:
#   ORBIT_RELEASE_TARGETS="x86_64-linux-gnu aarch64-linux-gnu"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version-tag>" >&2
  echo "example: $0 v0.1.0" >&2
  exit 1
fi

VERSION="$1"
if [[ "${VERSION}" != v* ]]; then
  echo "error: version tag must start with 'v' (got: ${VERSION})" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/${VERSION}"
TMP_DIR="${ROOT_DIR}/.zig-cache/release-${VERSION}"

mkdir -p "${DIST_DIR}" "${TMP_DIR}"

TARGETS="${ORBIT_RELEASE_TARGETS:-x86_64-linux-gnu aarch64-linux-gnu x86_64-macos-none aarch64-macos-none}"

echo "building orbit release artifacts for ${VERSION}"
for target in ${TARGETS}; do
  prefix="${TMP_DIR}/${target}"
  archive="orbit-${VERSION}-${target}.tar.gz"

  echo "  - target: ${target}"
  rm -rf "${prefix}"
  zig build --release=small -Dtarget="${target}" --prefix "${prefix}"

  if [[ ! -x "${prefix}/bin/orbit" ]]; then
    echo "error: missing binary for ${target}: ${prefix}/bin/orbit" >&2
    exit 1
  fi

  tar -C "${prefix}/bin" -czf "${DIST_DIR}/${archive}" orbit
done

(
  cd "${DIST_DIR}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum orbit-"${VERSION}"-*.tar.gz > checksums.txt
  else
    shasum -a 256 orbit-"${VERSION}"-*.tar.gz > checksums.txt
  fi
)

echo
echo "done."
echo "artifacts: ${DIST_DIR}"
echo "upload all *.tar.gz and checksums.txt to GitHub Release ${VERSION}"
