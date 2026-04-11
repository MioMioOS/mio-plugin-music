#!/bin/bash
# Build the Music Player plugin as a .bundle for MioIsland
set -e

PLUGIN_NAME="music-player"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"
BUILD_DIR="build"
SOURCES="Sources/*.swift"

echo "Building ${PLUGIN_NAME} plugin..."

# Clean
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS"

# Compile to dynamic library
swiftc \
    -emit-library \
    -module-name MusicPlugin \
    -target arm64-apple-macos15.0 \
    -sdk $(xcrun --show-sdk-path) \
    -o "${BUILD_DIR}/${BUNDLE_NAME}/Contents/MacOS/MusicPlugin" \
    ${SOURCES}

# Copy Info.plist
cp Info.plist "${BUILD_DIR}/${BUNDLE_NAME}/Contents/"

# Ad-hoc sign
codesign --force --sign - "${BUILD_DIR}/${BUNDLE_NAME}"

echo "✓ Built ${BUILD_DIR}/${BUNDLE_NAME}"
echo ""
echo "Install:"
echo "  cp -r ${BUILD_DIR}/${BUNDLE_NAME} ~/.config/codeisland/plugins/"
