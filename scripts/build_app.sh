#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
APP_NAME="Build Beacon.app"
DIST_DIR="${PROJECT_ROOT}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICON_ASSETS_DIR="${PROJECT_ROOT}/.build/icon-assets"
APP_ICON_PATH="${ICON_ASSETS_DIR}/BuildBeacon.icns"

cd "${PROJECT_ROOT}"
swift build -c "${BUILD_CONFIGURATION}" --arch arm64 --arch x86_64
"${PROJECT_ROOT}/scripts/make_icon.sh" >/dev/null

if [[ ! -s "${APP_ICON_PATH}" ]]; then
    echo "BuildBeacon icon was not produced at ${APP_ICON_PATH}" >&2
    exit 1
fi

BIN_DIR="$(swift build -c "${BUILD_CONFIGURATION}" --arch arm64 --arch x86_64 --show-bin-path)"
EXECUTABLE_PATH="${BIN_DIR}/BuildBeacon"

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
    echo "BuildBeacon executable was not produced at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

if [[ -e "${APP_DIR}" ]]; then
    rm -rf "${APP_DIR}"
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
ditto "${EXECUTABLE_PATH}" "${MACOS_DIR}/BuildBeacon"
ditto "${PROJECT_ROOT}/Config/Info.plist" "${CONTENTS_DIR}/Info.plist"
ditto "${APP_ICON_PATH}" "${RESOURCES_DIR}/BuildBeacon.icns"

ARCHITECTURES="$(lipo -archs "${MACOS_DIR}/BuildBeacon")"
if [[ " ${ARCHITECTURES} " != *" arm64 "* || " ${ARCHITECTURES} " != *" x86_64 "* ]]; then
    echo "BuildBeacon must contain arm64 and x86_64 slices; found: ${ARCHITECTURES}" >&2
    exit 1
fi

for resource_bundle in "${BIN_DIR}"/*.bundle(N); do
    ditto "${resource_bundle}" "${RESOURCES_DIR}/${resource_bundle:t}"
done

xattr -cr "${APP_DIR}"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SIGNING_TIMESTAMP="${SIGNING_TIMESTAMP:---timestamp=none}"
codesign \
    --force \
    --deep \
    --options runtime \
    "${SIGNING_TIMESTAMP}" \
    --entitlements "${PROJECT_ROOT}/Config/BuildBeacon.entitlements" \
    --sign "${SIGNING_IDENTITY}" \
    "${APP_DIR}"

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
plutil -lint "${CONTENTS_DIR}/Info.plist"

if [[ "$(plutil -extract CFBundleIconFile raw "${CONTENTS_DIR}/Info.plist")" != "BuildBeacon" ]]; then
    echo "Info.plist must declare BuildBeacon as the app icon." >&2
    exit 1
fi

if [[ ! -s "${RESOURCES_DIR}/BuildBeacon.icns" ]]; then
    echo "Build Beacon.app is missing its bundled icon." >&2
    exit 1
fi

echo "${APP_DIR}"
