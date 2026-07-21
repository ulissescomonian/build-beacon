#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
SOURCE_APP="${PROJECT_ROOT}/dist/Build Beacon.app"
TARGET_APP="/Applications/Build Beacon.app"
STAGING_APP="/Applications/.Build Beacon.app.installing.$$"
BACKUP_APP="/Applications/.Build Beacon.app.previous.$$"
REPLACED_EXISTING=false

cleanup() {
    rm -rf "${STAGING_APP}"
    if [[ "${REPLACED_EXISTING}" == true && ! -e "${TARGET_APP}" && -e "${BACKUP_APP}" ]]; then
        mv "${BACKUP_APP}" "${TARGET_APP}"
    fi
}
trap cleanup EXIT INT TERM

"${PROJECT_ROOT}/scripts/build_app.sh"

ditto "${SOURCE_APP}" "${STAGING_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

if pgrep -x BuildBeacon >/dev/null; then
    pkill -x BuildBeacon
    for _ in {1..50}; do
        pgrep -x BuildBeacon >/dev/null || break
        sleep 0.1
    done
    if pgrep -x BuildBeacon >/dev/null; then
        echo "BuildBeacon did not terminate before installation" >&2
        exit 1
    fi
fi

if [[ -e "${TARGET_APP}" ]]; then
    mv "${TARGET_APP}" "${BACKUP_APP}"
    REPLACED_EXISTING=true
fi

mv "${STAGING_APP}" "${TARGET_APP}"
codesign --verify --deep --strict --verbose=2 "${TARGET_APP}"
rm -rf "${BACKUP_APP}"
REPLACED_EXISTING=false
trap - EXIT INT TERM
open "${TARGET_APP}"

echo "${TARGET_APP}"
