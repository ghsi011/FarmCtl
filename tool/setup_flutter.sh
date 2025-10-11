#!/usr/bin/env bash
set -euo pipefail

# Determine repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="${FLUTTER_DIR:-${REPO_ROOT}/.tooling/flutter}"
FLUTTER_CHANNEL="${FLUTTER_CHANNEL:-stable}"
FLUTTER_VERSION="${FLUTTER_VERSION:-}"

mkdir -p "$(dirname "${FLUTTER_DIR}")"

if [ ! -d "${FLUTTER_DIR}" ]; then
  echo "Cloning Flutter SDK (${FLUTTER_CHANNEL}) into ${FLUTTER_DIR}" >&2
  git clone --depth 1 --branch "${FLUTTER_CHANNEL}" https://github.com/flutter/flutter.git "${FLUTTER_DIR}"
else
  echo "Updating existing Flutter SDK in ${FLUTTER_DIR}" >&2
  git -C "${FLUTTER_DIR}" fetch --depth 1 origin "${FLUTTER_CHANNEL}"
  git -C "${FLUTTER_DIR}" reset --hard FETCH_HEAD
fi

if [ -n "${FLUTTER_VERSION}" ]; then
  echo "Checking out Flutter version ${FLUTTER_VERSION}" >&2
  git -C "${FLUTTER_DIR}" fetch --depth 1 origin "refs/tags/${FLUTTER_VERSION}" || true
  if git -C "${FLUTTER_DIR}" rev-parse "${FLUTTER_VERSION}" >/dev/null 2>&1; then
    git -C "${FLUTTER_DIR}" checkout "${FLUTTER_VERSION}"
  else
    echo "Requested FLUTTER_VERSION ${FLUTTER_VERSION} was not found. Remaining on ${FLUTTER_CHANNEL}." >&2
  fi
fi

"${FLUTTER_DIR}/bin/flutter" --version
