#!/bin/bash
# Build the Music Player plugin as a .bundle for MioIsland
set -e

PLUGIN_NAME="music-player"
BUNDLE_NAME="${PLUGIN_NAME}.bundle"
BUILD_DIR="build"

# Recursively pick up every .swift under Sources/ (root + subdirectories
# like sources/, ui/, support/ for the v2.0.0 layered layout).
SOURCES=$(find Sources -name "*.swift" -type f)

echo "Building ${PLUGIN_NAME} plugin..."
echo "Compiling $(echo "$SOURCES" | wc -l | tr -d ' ') Swift files..."

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

# Bundle the MediaRemoteAdapter subprocess payload (Atoll-style).
# Resources/ contains `MediaRemoteAdapter.framework` + `mediaremote-adapter.pl`.
# Both are BSD-3-Clause by Jonas van den Berg (see LICENSE-THIRD-PARTY.md).
# We copy Resources/* into Contents/Resources so MediaRemoteAdapterSource
# can find them via Bundle(for:).path(forResource:ofType:).
if [ -d "Resources" ]; then
  mkdir -p "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources"
  cp -R Resources/* "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/"
  # Preserve framework executable bit (cp -R should, but be defensive)
  chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/MediaRemoteAdapter.framework/MediaRemoteAdapter" 2>/dev/null || true
  chmod +x "${BUILD_DIR}/${BUNDLE_NAME}/Contents/Resources/mediaremote-adapter.pl"
fi

# Ad-hoc sign the WHOLE bundle including the nested framework. Passing
# --deep traverses nested code signatures and re-signs them with our
# ad-hoc identity so the framework loads without Gatekeeper complaints
# when the plugin is dropped into ~/.config/codeisland/plugins/.
codesign --force --deep --sign - "${BUILD_DIR}/${BUNDLE_NAME}"

echo "✓ Built ${BUILD_DIR}/${BUNDLE_NAME}"

# Create zip for marketplace upload
cd "${BUILD_DIR}"
zip -r "${PLUGIN_NAME}.zip" "${BUNDLE_NAME}"
cd ..

echo "✓ Created ${BUILD_DIR}/${PLUGIN_NAME}.zip (for marketplace upload)"
echo ""
echo "Install locally:"
echo "  cp -r ${BUILD_DIR}/${BUNDLE_NAME} ~/.config/codeisland/plugins/"
echo ""
echo "Upload to marketplace:"
echo "  ${BUILD_DIR}/${PLUGIN_NAME}.zip"
