#!/usr/bin/env bash
set -euo pipefail

# Orbit installer.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
#
# Optional env:
#   ORBIT_VERSION=v0.1.0
#   ORBIT_REPO=duanfuxiang0/orbit
#   ORBIT_INSTALL_DIR=$HOME/.local/bin

ORBIT_REPO="${ORBIT_REPO:-duanfuxiang0/orbit}"
ORBIT_INSTALL_DIR="${ORBIT_INSTALL_DIR:-$HOME/.local/bin}"

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *)
      echo "unsupported OS: ${os}" >&2
      exit 1
      ;;
  esac

  case "${arch}" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *)
      echo "unsupported architecture: ${arch}" >&2
      exit 1
      ;;
  esac

  if [[ "${os}" == "linux" ]]; then
    echo "${arch}-linux-gnu"
  else
    echo "${arch}-macos-none"
  fi
}

fetch_latest_version() {
  local api tag
  api="https://api.github.com/repos/${ORBIT_REPO}/releases/latest"
  tag="$(curl -fsSL "${api}" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -z "${tag}" ]]; then
    echo "failed to detect latest release tag from ${api}" >&2
    exit 1
  fi
  echo "${tag}"
}

verify_checksum() {
  local file checksums expected actual
  file="$1"
  checksums="$2"

  expected="$(grep "  $(basename "${file}")$" "${checksums}" | awk '{print $1}')"
  if [[ -z "${expected}" ]]; then
    echo "checksum entry not found for $(basename "${file}")" >&2
    exit 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  fi

  if [[ "${expected}" != "${actual}" ]]; then
    echo "checksum mismatch for $(basename "${file}")" >&2
    echo "expected: ${expected}" >&2
    echo "actual:   ${actual}" >&2
    exit 1
  fi
}

main() {
  local version target base_url archive tmpdir archive_path checksums_path

  version="${ORBIT_VERSION:-}"
  if [[ -z "${version}" ]]; then
    version="$(fetch_latest_version)"
  fi

  target="$(detect_target)"
  archive="orbit-${version}-${target}.tar.gz"
  base_url="https://github.com/${ORBIT_REPO}/releases/download/${version}"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  archive_path="${tmpdir}/${archive}"
  checksums_path="${tmpdir}/checksums.txt"

  echo "installing orbit ${version} for ${target}"
  curl -fL "${base_url}/${archive}" -o "${archive_path}"
  curl -fL "${base_url}/checksums.txt" -o "${checksums_path}"

  verify_checksum "${archive_path}" "${checksums_path}"

  mkdir -p "${ORBIT_INSTALL_DIR}"
  tar -xzf "${archive_path}" -C "${tmpdir}"
  install -m 0755 "${tmpdir}/orbit" "${ORBIT_INSTALL_DIR}/orbit"

  echo "orbit installed to ${ORBIT_INSTALL_DIR}/orbit"
  case ":$PATH:" in
    *":${ORBIT_INSTALL_DIR}:"*) ;;
    *)
      echo
      echo "note: ${ORBIT_INSTALL_DIR} is not in PATH."
      echo "add this line to your shell profile:"
      echo "  export PATH=\"${ORBIT_INSTALL_DIR}:\$PATH\""
      ;;
  esac
}

main "$@"
