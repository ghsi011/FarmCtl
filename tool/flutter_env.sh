#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FLUTTER_ROOT="${FLUTTER_ROOT:-${REPO_ROOT}/.tooling/flutter}"
export PATH="${FLUTTER_ROOT}/bin:${PATH}"
