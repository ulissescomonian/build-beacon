#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_NAME="Build Beacon.app"
DIST_DIR="${PROJECT_ROOT}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}"
INFO_PLIST="${APP_DIR}/Contents/Info.plist"
STAGING_DIR=""

cleanup() {
    if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT INT TERM

if [[ ! -d "${APP_DIR}" ]]; then
    "${PROJECT_ROOT}/scripts/build_app.sh"
fi

if [[ ! -d "${APP_DIR}" || ! -f "${INFO_PLIST}" ]]; then
    echo "Expected app bundle at ${APP_DIR}" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

EXECUTABLE_PATH="${APP_DIR}/Contents/MacOS/BuildBeacon"
if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
    echo "Expected executable at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

ARCHITECTURES="$(lipo -archs "${EXECUTABLE_PATH}")"
if [[ " ${ARCHITECTURES} " != *" arm64 "* || " ${ARCHITECTURES} " != *" x86_64 "* ]]; then
    echo "BuildBeacon must contain arm64 and x86_64 slices; found: ${ARCHITECTURES}" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
if [[ -z "${VERSION}" ]]; then
    echo "CFBundleShortVersionString is required in ${INFO_PLIST}" >&2
    exit 1
fi

DMG_NAME="Build-Beacon-${VERSION}-universal.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
CHECKSUM_PATH="${DMG_PATH}.sha256"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-beacon-dmg.XXXXXX")"
ditto "${APP_DIR}" "${STAGING_DIR}/${APP_NAME}"
ln -s /Applications "${STAGING_DIR}/Applications"

if [[ -e "${DMG_PATH}" ]]; then
    rm -f "${DMG_PATH}"
fi
if [[ -e "${CHECKSUM_PATH}" ]]; then
    rm -f "${CHECKSUM_PATH}"
fi

hdiutil create \
    -volname "Build Beacon" \
    -srcfolder "${STAGING_DIR}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"

(
    cd "${DIST_DIR}"
    shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

echo "${DMG_PATH}"
echo "${CHECKSUM_PATH}"
