#!/bin/bash
set -euo pipefail

# Load signing config from .env.local (not committed to repo)
[ -f .env.local ] && source .env.local

# ── Config ────────────────────────────────────────────────
APP_NAME="PromptBuilder"
BUNDLE_ID="com.whitehappypony.prompt-builder"
DISPLAY_NAME="Prompt Builder"
MIN_OS="13.0"
LSUIELEMENT="false"
EXTRA_BUNDLES=""  # space-separated resource bundles to copy
# ── Signing identity (loaded from .env.local) ─
IDENTITY="${IDENTITY:?Set IDENTITY in .env.local}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"
# ───────────────────────────────────────────────────────────

APP="${APP_NAME}.app"
DMG="${APP_NAME}.dmg"
BINARY=".build/apple/Products/Release/${APP_NAME}"

step() { echo ""; echo "── $1"; }

case "${1:-release}" in

build)
    step "Building universal binary"
    swift build -c release --arch arm64 --arch x86_64
    ;;

app)
    $0 build
    step "Creating ${APP}"
    rm -rf "${APP}"
    mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
    cp "${BINARY}" "${APP}/Contents/MacOS/"
    [ -f AppIcon.icns ] && cp AppIcon.icns "${APP}/Contents/Resources/"

    # Copy extra resource bundles (e.g. KeyboardShortcuts)
    for bundle in ${EXTRA_BUNDLES}; do
        src=".build/apple/Products/Release/${bundle}"
        [ -d "${src}" ] && cp -R "${src}" "${APP}/Contents/Resources/"
    done

    cat > "${APP}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><${LSUIELEMENT}/>
    <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    echo "✓ ${APP} created"
    ;;

sign)
    $0 app
    step "Signing ${APP}"
    # Sign any embedded bundles first
    find "${APP}/Contents/Resources" -name "*.bundle" -exec \
        codesign --force --options runtime --timestamp --sign "${IDENTITY}" {} \;
    # Sign the app
    codesign --force --options runtime --timestamp \
        --sign "${IDENTITY}" "${APP}"
    codesign --verify --verbose=2 "${APP}"
    echo "✓ Signed"
    ;;

notarize)
    $0 sign
    step "Notarizing"
    ditto -c -k --keepParent "${APP}" "/tmp/${APP_NAME}.zip"
    xcrun notarytool submit "/tmp/${APP_NAME}.zip" \
        --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP}"
    rm "/tmp/${APP_NAME}.zip"
    echo "✓ Notarized & stapled"
    ;;

dmg)
    $0 notarize
    step "Creating ${DMG}"
    rm -f "${DMG}"
    STAGING="$(mktemp -d)"
    cp -R "${APP}" "${STAGING}/"
    ln -s /Applications "${STAGING}/Applications"
    hdiutil create -volname "${DISPLAY_NAME}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}"
    rm -rf "${STAGING}"
    echo "✓ ${DMG} ready"
    ;;

release)
    $0 dmg
    step "Done"
    echo "Upload ${DMG} to GitHub Releases"
    echo "  gh release create vX.Y.Z ${DMG} --title '${DISPLAY_NAME} vX.Y.Z'"
    ;;

clean)
    rm -rf .build "${APP}" "${DMG}"
    echo "✓ Cleaned"
    ;;

*)
    echo "Usage: $0 {build|app|sign|notarize|dmg|release|clean}"
    exit 1
    ;;
esac
