#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
MASTER_ICON="${PROJECT_ROOT}/Resources/BuildBeaconIcon-1024.png"
ICON_ASSETS_DIR="${PROJECT_ROOT}/.build/icon-assets"
ICONSET_DIR="${ICON_ASSETS_DIR}/BuildBeacon.iconset"
OUTPUT_ICON="${ICON_ASSETS_DIR}/BuildBeacon.icns"

if [[ ! -f "${MASTER_ICON}" ]]; then
    echo "Missing master icon: ${MASTER_ICON}" >&2
    exit 1
fi

master_width="$(sips -g pixelWidth "${MASTER_ICON}" | awk '/pixelWidth:/ { print $2 }')"
master_height="$(sips -g pixelHeight "${MASTER_ICON}" | awk '/pixelHeight:/ { print $2 }')"
master_alpha="$(sips -g hasAlpha "${MASTER_ICON}" | awk '/hasAlpha:/ { print $2 }')"

if [[ "${master_width}" != "1024" || "${master_height}" != "1024" || "${master_alpha}" != "yes" ]]; then
    echo "Master icon must be a 1024×1024 PNG with alpha transparency." >&2
    exit 1
fi

rm -rf "${ICONSET_DIR}" "${OUTPUT_ICON}"
mkdir -p "${ICONSET_DIR}"

typeset -a icon_variants
icon_variants=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

for variant in "${icon_variants[@]}"; do
    filename="${variant%%:*}"
    pixels="${variant##*:}"
    output="${ICONSET_DIR}/${filename}"

    sips --resampleHeightWidth "${pixels}" "${pixels}" \
        --matchTo "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
        --setProperty format png \
        "${MASTER_ICON}" \
        --out "${output}" >/dev/null

    width="$(sips -g pixelWidth "${output}" | awk '/pixelWidth:/ { print $2 }')"
    height="$(sips -g pixelHeight "${output}" | awk '/pixelHeight:/ { print $2 }')"
    alpha="$(sips -g hasAlpha "${output}" | awk '/hasAlpha:/ { print $2 }')"

    if [[ "${width}" != "${pixels}" || "${height}" != "${pixels}" || "${alpha}" != "yes" ]]; then
        echo "Invalid icon variant: ${output}" >&2
        exit 1
    fi
done

iconutil --convert icns "${ICONSET_DIR}" --output "${OUTPUT_ICON}"

if [[ ! -s "${OUTPUT_ICON}" ]]; then
    echo "iconutil did not create ${OUTPUT_ICON}" >&2
    exit 1
fi

echo "${OUTPUT_ICON}"
